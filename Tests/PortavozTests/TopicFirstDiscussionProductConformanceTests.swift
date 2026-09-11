import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class TopicFirstDiscussionProductConformanceTests: XCTestCase {
    func testCanonicalFirstDiscussionCasesTraverseProductPath() async throws {
        let fixture = try FirstDiscussionFixtureDocument.load()
        let cases = fixture.cases.filter { $0.job == "firstDiscussion" }

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
            let adapter = try await FirstDiscussionProductAdapter(fixtureCase)
            let result = try await LoadTopicFirstDiscussion(
                repository: adapter.store
            ).execute(TopicFirstDiscussionQuery(topicID: adapter.topicID))

            try assert(
                result,
                matches: fixtureCase.expected,
                adapter: adapter,
                caseID: fixtureCase.id)
        }
    }

    private func assert(
        _ result: MeetingMemoryGraphQueryResult,
        matches expected: FirstDiscussionExpected,
        adapter: FirstDiscussionProductAdapter,
        caseID: String
    ) throws {
        switch result {
        case .facts(let page):
            XCTAssertEqual(expected.answerPolicy, "answer", caseID)
            let resultIDs = try page.facts.map { fact in
                guard case .topicEvidence(let evidenceID) = fact.id else {
                    throw FirstDiscussionFixtureError.invalid(
                        "\(caseID): product returned a non-topic fact")
                }
                return try XCTUnwrap(
                    adapter.externalFactIDByEvidenceID[evidenceID],
                    "\(caseID): product returned unmapped topic evidence")
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
            XCTAssertEqual(expected.abstentionReason, "staleEvidenceOnly", caseID)
            XCTAssertEqual(reason, .staleEvidenceOnly, caseID)
            XCTAssertTrue(expected.resultIDs.isEmpty, caseID)
            XCTAssertTrue(expected.evidenceIDs.isEmpty, caseID)
        }
    }
}

private struct FirstDiscussionProductAdapter {
    let store: MeetingStore
    let topicID: TopicID
    let externalFactIDByEvidenceID: [TopicMeetingEvidenceID: String]
    let externalEvidenceIDBySegmentID: [UUID: String]

    init(_ fixtureCase: FirstDiscussionCase) async throws {
        let store = try MeetingStore.inMemory()
        let namespace = "first-discussion-product-\(fixtureCase.id)"
        let meetingIDs = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.meetings.map { source in
                (
                    source.id,
                    MeetingID(rawValue: try Self.identifier(
                        namespace: namespace,
                        externalID: source.id))
                )
            })
        let evidenceByID = Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { ($0.id, $0) })
        let segmentIDs = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { source in
                (
                    source.id,
                    try Self.identifier(
                        namespace: namespace,
                        externalID: source.segmentID)
                )
            })
        let sequenceByMeetingID = Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.meetings.map { ($0.id, $0.sequence) })

        var meetingsByExternalID: [String: Meeting] = [:]
        for source in fixtureCase.corpus.meetings.sorted(by: {
            $0.sequence < $1.sequence
        }) {
            let startedAt = Self.baseDate.addingTimeInterval(
                TimeInterval(source.sequence * 100))
            let meeting = Meeting(
                id: try Self.required(
                    meetingIDs[source.id],
                    "unknown meeting \(source.id)"),
                title: source.title,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60),
                transcriptRevision: fixtureCase.corpus.evidence
                    .filter { $0.meetingID == source.id }
                    .map(\.transcriptRevision).max() ?? 0)
            try await store.save(meeting)
            meetingsByExternalID[source.id] = meeting
        }

        try await store.save(try fixtureCase.corpus.evidence.map { source in
            TranscriptSegment(
                id: try Self.required(
                    segmentIDs[source.id],
                    "unknown evidence \(source.id)"),
                meetingID: try Self.required(
                    meetingIDs[source.meetingID],
                    "unknown evidence meeting \(source.meetingID)"),
                channel: .system,
                text: source.text,
                language: source.language,
                startTime: TimeInterval(source.timestampMilliseconds) / 1_000,
                endTime: TimeInterval(source.timestampMilliseconds) / 1_000 + 1,
                confidence: 1,
                isFinal: true)
        })

        let mentions = fixtureCase.corpus.facts.filter {
            $0.kind == "topicMention"
        }
        let mentionsBySubject = Dictionary(grouping: mentions, by: \.subjectID)
        let querySubjects = mentionsBySubject
            .filter { $0.value.count == 2 }
            .map(\.key)
            .sorted()
        guard querySubjects.count == 1, let querySubject = querySubjects.first else {
            throw FirstDiscussionFixtureError.invalid(
                "\(fixtureCase.id): first-discussion subject is ambiguous")
        }

        var rootTopicBySubject: [String: TopicID] = [:]
        var externalFactIDByEvidenceID: [TopicMeetingEvidenceID: String] = [:]
        for subject in mentionsBySubject.keys.sorted() {
            let subjectMentions = try Self.sortedMentions(
                mentionsBySubject[subject] ?? [],
                evidenceByID: evidenceByID,
                sequenceByMeetingID: sequenceByMeetingID)
            for (index, fact) in subjectMentions.enumerated() {
                let source = try Self.oneEvidence(
                    fact,
                    evidenceByID: evidenceByID)
                let proposal = TopicLinkProposal(
                    meetingID: try Self.required(
                        meetingIDs[source.meetingID],
                        "unknown topic meeting \(source.meetingID)"),
                    segmentID: try Self.required(
                        segmentIDs[source.id],
                        "unknown topic evidence \(source.id)"),
                    sourceTranscriptRevision: source.transcriptRevision,
                    observedLabel: subject,
                    language: source.language,
                    origin: .manual,
                    confirmedAt: Self.baseDate.addingTimeInterval(
                        TimeInterval(source.timestampMilliseconds) / 1_000))
                let confirmed: ConfirmedTopicLink
                if index == 0 {
                    confirmed = try await store.createTopicAndLink(proposal)
                    rootTopicBySubject[subject] = confirmed.topic.id
                } else {
                    confirmed = try await store.linkTopic(
                        proposal,
                        to: try Self.required(
                            rootTopicBySubject[subject],
                            "missing root topic for \(subject)"))
                }
                externalFactIDByEvidenceID[confirmed.evidence.id] = fact.id
            }
        }

        if mentionsBySubject[querySubject]?.allSatisfy(\.stale) == true {
            let staleMeetingIDs = try Set(
                (mentionsBySubject[querySubject] ?? []).map { fact in
                    try Self.oneEvidence(
                        fact,
                        evidenceByID: evidenceByID).meetingID
                })
            for externalMeetingID in staleMeetingIDs.sorted() {
                var meeting = try Self.required(
                    meetingsByExternalID[externalMeetingID],
                    "unknown stale meeting \(externalMeetingID)")
                meeting.transcriptRevision += 1
                try await store.save(meeting)
                meetingsByExternalID[externalMeetingID] = meeting
            }
        }

        try await projectFirstDiscussionProductGraph(in: store)

        self.store = store
        self.topicID = try Self.required(
            rootTopicBySubject[querySubject],
            "missing queried topic")
        self.externalFactIDByEvidenceID = externalFactIDByEvidenceID
        self.externalEvidenceIDBySegmentID = Dictionary(uniqueKeysWithValues:
            segmentIDs.map { ($0.value, $0.key) })
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_787_100_000)

    private static func sortedMentions(
        _ facts: [FirstDiscussionFact],
        evidenceByID: [String: FirstDiscussionEvidence],
        sequenceByMeetingID: [String: Int]
    ) throws -> [FirstDiscussionFact] {
        try facts.sorted { left, right in
            let leftEvidence = try oneEvidence(left, evidenceByID: evidenceByID)
            let rightEvidence = try oneEvidence(right, evidenceByID: evidenceByID)
            let leftOrder = (
                try required(
                    sequenceByMeetingID[leftEvidence.meetingID],
                    "unknown meeting sequence"),
                leftEvidence.timestampMilliseconds,
                left.id)
            let rightOrder = (
                try required(
                    sequenceByMeetingID[rightEvidence.meetingID],
                    "unknown meeting sequence"),
                rightEvidence.timestampMilliseconds,
                right.id)
            return leftOrder < rightOrder
        }
    }

    private static func oneEvidence(
        _ fact: FirstDiscussionFact,
        evidenceByID: [String: FirstDiscussionEvidence]
    ) throws -> FirstDiscussionEvidence {
        guard fact.evidenceIDs.count == 1,
              let externalID = fact.evidenceIDs.first
        else {
            throw FirstDiscussionFixtureError.invalid(
                "\(fact.id): topic mention requires one evidence item")
        }
        return try required(
            evidenceByID[externalID],
            "unknown evidence \(externalID)")
    }

    private static func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw FirstDiscussionFixtureError.invalid(message)
        }
        return value
    }

    private static func identifier(
        namespace: String,
        externalID: String
    ) throws -> UUID {
        let digest = OperationFingerprint.make(
            version: namespace,
            components: [externalID])
        let compact = String(digest.prefix(32))
        let value = [
            compact.prefix(8),
            compact.dropFirst(8).prefix(4),
            compact.dropFirst(12).prefix(4),
            compact.dropFirst(16).prefix(4),
            compact.dropFirst(20).prefix(12),
        ].map(String.init).joined(separator: "-")
        guard let identifier = UUID(uuidString: value) else {
            throw FirstDiscussionFixtureError.invalid(
                "deterministic identity is invalid")
        }
        return identifier
    }
}

private func projectFirstDiscussionProductGraph(
    in store: MeetingStore
) async throws {
    let owner = "first-discussion-conformance-\(UUID().uuidString)"
    let timestamp = Date().addingTimeInterval(10)
    _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
    guard let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp
    ) else {
        throw FirstDiscussionFixtureError.invalid(
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

private struct FirstDiscussionFixtureDocument: Decodable {
    let kind: String
    let schemaVersion: Int
    let generation: String
    let cases: [FirstDiscussionCase]

    static func load() throws -> FirstDiscussionFixtureDocument {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("MeetingMemoryGraph", isDirectory: true)
            .appendingPathComponent("public-synthetic-v1.json")
        return try JSONDecoder().decode(
            FirstDiscussionFixtureDocument.self,
            from: Data(contentsOf: url))
    }
}

private struct FirstDiscussionCase: Decodable {
    let id: String
    let job: String
    let relationship: String
    let corpus: FirstDiscussionCorpus
    let expected: FirstDiscussionExpected
}

private struct FirstDiscussionCorpus: Decodable {
    let evidence: [FirstDiscussionEvidence]
    let facts: [FirstDiscussionFact]
    let meetings: [FirstDiscussionMeeting]
}

private struct FirstDiscussionEvidence: Decodable {
    let id: String
    let language: String
    let meetingID: String
    let segmentID: String
    let text: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

private struct FirstDiscussionFact: Decodable {
    let evidenceIDs: [String]
    let id: String
    let kind: String
    let stale: Bool
    let subjectID: String
}

private struct FirstDiscussionMeeting: Decodable {
    let id: String
    let sequence: Int
    let title: String
}

private struct FirstDiscussionExpected: Decodable {
    let abstentionReason: String?
    let answerPolicy: String
    let evidenceIDs: [String]
    let forbiddenResultIDs: [String]
    let resultIDs: [String]
}

private enum FirstDiscussionFixtureError: Error {
    case invalid(String)
}
