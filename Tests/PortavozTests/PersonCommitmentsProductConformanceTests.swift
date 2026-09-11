import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class PersonCommitmentsProductConformanceTests: XCTestCase {
    func testCanonicalPersonCommitmentCasesTraverseProductPath() async throws {
        let fixture = try PersonCommitmentsFixtureDocument.load()
        let cases = fixture.cases.filter { $0.job == "personCommitments" }

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
            let adapter = try await PersonCommitmentsProductAdapter(fixtureCase)
            let result = try await LoadPersonCommitmentsByAlias(
                people: adapter.store,
                commitments: adapter.store
            ).execute(PersonCommitmentsAliasQuery(alias: adapter.queryAlias))

            try assert(
                result,
                matches: fixtureCase.expected,
                adapter: adapter,
                caseID: fixtureCase.id)
        }
    }

    private func assert(
        _ result: MeetingMemoryGraphQueryResult,
        matches expected: PersonCommitmentsExpected,
        adapter: PersonCommitmentsProductAdapter,
        caseID: String
    ) throws {
        switch result {
        case .facts(let page):
            XCTAssertEqual(expected.answerPolicy, "answer", caseID)
            let resultIDs = try page.facts.map { fact in
                guard case .commitment(let commitmentID) = fact.id else {
                    throw PersonCommitmentsFixtureError.invalid(
                        "\(caseID): product returned a non-commitment fact")
                }
                return try XCTUnwrap(
                    adapter.externalFactIDByCommitmentID[commitmentID],
                    "\(caseID): product returned an unmapped commitment")
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
            XCTAssertEqual(expected.abstentionReason, "ambiguousPerson", caseID)
            XCTAssertEqual(reason, .ambiguousPerson, caseID)
            XCTAssertTrue(expected.resultIDs.isEmpty, caseID)
            XCTAssertTrue(expected.evidenceIDs.isEmpty, caseID)
        }
    }
}

private struct PersonCommitmentsProductAdapter {
    let store: MeetingStore
    let queryAlias: String
    let externalFactIDByCommitmentID: [CommitmentID: String]
    let externalEvidenceIDBySegmentID: [UUID: String]

    init(_ fixtureCase: PersonCommitmentsFixtureCase) async throws {
        let store = try MeetingStore.inMemory()
        let namespace = "person-commitments-product-\(fixtureCase.id)"
        let evidenceByID = Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { ($0.id, $0) })
        let meetingIDs = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.meetings.map { meeting in
                (
                    meeting.id,
                    MeetingID(rawValue: try Self.identifier(
                        namespace: namespace,
                        externalID: meeting.id))
                )
            })
        let segmentIDs = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { evidence in
                (
                    evidence.id,
                    try Self.identifier(
                        namespace: namespace,
                        externalID: evidence.segmentID)
                )
            })

        for source in fixtureCase.corpus.meetings.sorted(by: {
            $0.sequence < $1.sequence
        }) {
            let startedAt = Self.baseDate.addingTimeInterval(
                TimeInterval(source.sequence * 100))
            try await store.save(Meeting(
                id: try Self.required(
                    meetingIDs[source.id],
                    "unknown meeting \(source.id)"),
                title: source.title,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60),
                transcriptRevision: fixtureCase.corpus.evidence
                    .filter { $0.meetingID == source.id }
                    .map(\.transcriptRevision).max() ?? 0))
        }

        let facts = fixtureCase.corpus.facts.filter {
            $0.kind == "commitment" && $0.predicate == "committedTo"
        }
        guard facts.count == fixtureCase.corpus.facts.count else {
            throw PersonCommitmentsFixtureError.invalid(
                "\(fixtureCase.id): unexpected non-commitment fact")
        }

        var speakerIDByFactID: [String: SpeakerID] = [:]
        for (index, fact) in facts.enumerated() {
            let evidence = try Self.oneEvidence(fact, evidenceByID: evidenceByID)
            let speakerID = SpeakerID(rawValue: try Self.identifier(
                namespace: namespace,
                externalID: "speaker-\(fact.id)"))
            try await store.save([Speaker(
                id: speakerID,
                meetingID: try Self.required(
                    meetingIDs[evidence.meetingID],
                    "unknown speaker meeting \(evidence.meetingID)"),
                label: "S\(index + 1)",
                displayName: Self.displayName(for: fact.objectID))])
            speakerIDByFactID[fact.id] = speakerID
        }

        var personIDByExternalID: [String: PersonID] = [:]
        for fact in facts {
            let speakerID = try Self.required(
                speakerIDByFactID[fact.id],
                "missing speaker for \(fact.id)")
            let alias = Self.displayName(for: fact.objectID)
            if let personID = personIDByExternalID[fact.objectID] {
                _ = try await store.linkSpeaker(
                    speakerID,
                    to: personID,
                    observedAlias: alias,
                    source: .manualName)
            } else {
                let link = try await store.createPersonAndLink(
                    speakerID: speakerID,
                    preferredName: alias,
                    source: .manualName)
                personIDByExternalID[fact.objectID] = link.person.id
            }
        }

        try await store.save(try facts.map { fact in
            let evidence = try Self.oneEvidence(fact, evidenceByID: evidenceByID)
            return TranscriptSegment(
                id: try Self.required(
                    segmentIDs[evidence.id],
                    "missing segment for \(evidence.id)"),
                meetingID: try Self.required(
                    meetingIDs[evidence.meetingID],
                    "unknown evidence meeting \(evidence.meetingID)"),
                speakerID: try Self.required(
                    speakerIDByFactID[fact.id],
                    "missing evidence speaker for \(fact.id)"),
                channel: .system,
                text: evidence.text,
                language: evidence.language,
                startTime: TimeInterval(evidence.timestampMilliseconds) / 1_000,
                endTime: TimeInterval(evidence.timestampMilliseconds) / 1_000 + 1,
                confidence: 1,
                isFinal: true)
        })

        let generatedFacts = facts.filter { $0.origin == "confirmed" }
        var actionItemIDByFactID: [String: UUID] = [:]
        let generatedByMeeting = try Dictionary(grouping: generatedFacts) { fact in
            try Self.oneEvidence(fact, evidenceByID: evidenceByID).meetingID
        }
        for externalMeetingID in generatedByMeeting.keys.sorted() {
            let meetingFacts = try Self.required(
                generatedByMeeting[externalMeetingID],
                "missing generated facts for \(externalMeetingID)")
            var items: [ActionItem] = []
            var itemEvidence: [SummaryActionItemEvidence] = []
            for fact in meetingFacts.sorted(by: { $0.id < $1.id }) {
                let source = try Self.oneEvidence(fact, evidenceByID: evidenceByID)
                let actionItemID = try Self.identifier(
                    namespace: namespace,
                    externalID: "action-\(fact.id)")
                actionItemIDByFactID[fact.id] = actionItemID
                items.append(ActionItem(
                    id: actionItemID,
                    text: source.text,
                    ownerSpeakerID: try Self.required(
                        speakerIDByFactID[fact.id],
                        "missing action-item speaker for \(fact.id)")))
                itemEvidence.append(SummaryActionItemEvidence(
                    actionItemID: actionItemID,
                    sourceTranscriptRevision: source.transcriptRevision,
                    evidenceSegmentIDs: [try Self.required(
                        segmentIDs[source.id],
                        "missing action-item evidence for \(fact.id)")]))
            }
            _ = try await store.saveSummary(SummaryDraft(
                meetingID: try Self.required(
                    meetingIDs[externalMeetingID],
                    "unknown summary meeting \(externalMeetingID)"),
                recipeID: "person-commitments-conformance",
                language: try Self.oneEvidence(
                    meetingFacts[0],
                    evidenceByID: evidenceByID).language,
                markdown: items.map { "- \($0.text)" }.joined(separator: "\n"),
                actionItems: items,
                actionItemEvidence: itemEvidence))
        }

        var externalFactIDByCommitmentID: [CommitmentID: String] = [:]
        for (index, fact) in facts.enumerated() {
            let source = try Self.oneEvidence(fact, evidenceByID: evidenceByID)
            let commitmentID = CommitmentID(rawValue: try Self.identifier(
                namespace: namespace,
                externalID: fact.subjectID))
            let assignee = CommitmentAssignee.person(try Self.required(
                personIDByExternalID[fact.objectID],
                "missing person for \(fact.objectID)"))
            let origin: CommitmentOrigin
            switch fact.origin {
            case "confirmed":
                origin = .generatedActionItem(try Self.required(
                    actionItemIDByFactID[fact.id],
                    "missing action item for \(fact.id)"))
            case "manual":
                origin = .manual(meetingID: try Self.required(
                    meetingIDs[source.meetingID],
                    "unknown manual meeting \(source.meetingID)"))
            default:
                throw PersonCommitmentsFixtureError.invalid(
                    "\(fact.id): unsupported origin \(fact.origin)")
            }
            _ = try await store.confirmCommitment(
                CommitmentConfirmation(
                    commitmentID: commitmentID,
                    title: source.text,
                    assignee: assignee,
                    origin: origin),
                at: Self.baseDate.addingTimeInterval(Double(index + 10)))
            if fact.status == "completed" {
                _ = try await store.applyCommitmentTransition(
                    .complete,
                    to: commitmentID,
                    sourceMeetingID: try Self.required(
                        meetingIDs[source.meetingID],
                        "unknown completion meeting \(source.meetingID)"),
                    at: Self.baseDate.addingTimeInterval(Double(index + 20)))
            } else if fact.status != "open" {
                throw PersonCommitmentsFixtureError.invalid(
                    "\(fact.id): unsupported status \(fact.status)")
            }
            externalFactIDByCommitmentID[commitmentID] = fact.id
        }

        try await projectPersonCommitmentsProductGraph(in: store)

        self.store = store
        self.queryAlias = try Self.queryAlias(
            for: fixtureCase,
            facts: facts)
        self.externalFactIDByCommitmentID = externalFactIDByCommitmentID
        self.externalEvidenceIDBySegmentID = Dictionary(uniqueKeysWithValues:
            segmentIDs.map { ($0.value, $0.key) })
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_787_100_000)

    private static func queryAlias(
        for fixtureCase: PersonCommitmentsFixtureCase,
        facts: [PersonCommitmentsFact]
    ) throws -> String {
        if let expectedID = fixtureCase.expected.resultIDs.first,
           let expected = facts.first(where: { $0.id == expectedID }) {
            return displayName(for: expected.objectID)
        }
        let aliases = Set(facts
            .filter { $0.status == "open" }
            .map { displayName(for: $0.objectID) })
        guard aliases.count == 1, let alias = aliases.first else {
            throw PersonCommitmentsFixtureError.invalid(
                "\(fixtureCase.id): abstention alias is not ambiguous by identity")
        }
        return alias
    }

    private static func displayName(for externalPersonID: String) -> String {
        if externalPersonID.hasPrefix("person-alex-") { return "Alex" }
        return externalPersonID
            .replacingOccurrences(of: "person-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func oneEvidence(
        _ fact: PersonCommitmentsFact,
        evidenceByID: [String: PersonCommitmentsEvidence]
    ) throws -> PersonCommitmentsEvidence {
        guard fact.evidenceIDs.count == 1,
              let externalID = fact.evidenceIDs.first
        else {
            throw PersonCommitmentsFixtureError.invalid(
                "\(fact.id): commitment requires one evidence item")
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
            throw PersonCommitmentsFixtureError.invalid(message)
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
            throw PersonCommitmentsFixtureError.invalid(
                "deterministic identity is invalid")
        }
        return identifier
    }
}

private func projectPersonCommitmentsProductGraph(
    in store: MeetingStore
) async throws {
    let owner = "person-commitments-conformance-\(UUID().uuidString)"
    let timestamp = Date().addingTimeInterval(10)
    _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
    guard let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp
    ) else {
        throw PersonCommitmentsFixtureError.invalid(
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

private struct PersonCommitmentsFixtureDocument: Decodable {
    let kind: String
    let schemaVersion: Int
    let generation: String
    let cases: [PersonCommitmentsFixtureCase]

    static func load() throws -> PersonCommitmentsFixtureDocument {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("MeetingMemoryGraph", isDirectory: true)
            .appendingPathComponent("public-synthetic-v1.json")
        return try JSONDecoder().decode(
            PersonCommitmentsFixtureDocument.self,
            from: Data(contentsOf: url))
    }
}

private struct PersonCommitmentsFixtureCase: Decodable {
    let id: String
    let job: String
    let relationship: String
    let corpus: PersonCommitmentsCorpus
    let expected: PersonCommitmentsExpected
}

private struct PersonCommitmentsCorpus: Decodable {
    let evidence: [PersonCommitmentsEvidence]
    let facts: [PersonCommitmentsFact]
    let meetings: [PersonCommitmentsMeeting]
}

private struct PersonCommitmentsEvidence: Decodable {
    let id: String
    let language: String
    let meetingID: String
    let segmentID: String
    let text: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

private struct PersonCommitmentsFact: Decodable {
    let evidenceIDs: [String]
    let id: String
    let kind: String
    let objectID: String
    let origin: String
    let predicate: String
    let status: String
    let subjectID: String
}

private struct PersonCommitmentsMeeting: Decodable {
    let id: String
    let sequence: Int
    let title: String
}

private struct PersonCommitmentsExpected: Decodable {
    let abstentionReason: String?
    let answerPolicy: String
    let evidenceIDs: [String]
    let forbiddenResultIDs: [String]
    let resultIDs: [String]
}

private enum PersonCommitmentsFixtureError: Error {
    case invalid(String)
}
