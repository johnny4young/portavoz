import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class TopicContinuityTests: XCTestCase {
    func testAliasNormalizationKeepsPresentationSeparateFromIdentity() {
        XCTAssertEqual(
            TopicAliasNormalizer.displayLabel("  Diseño\t de   APIs  "),
            "Diseño de APIs")
        XCTAssertEqual(
            TopicAliasNormalizer.normalize(" DISEÑO de ＡＰＩs "),
            "diseno de apis")
        XCTAssertEqual(TopicAliasNormalizer.language(" ES-mx "), "es-mx")
        XCTAssertNil(TopicAliasNormalizer.normalize(" \n "))

        let first = Topic(preferredLabel: "Diseño de APIs")
        let second = Topic(preferredLabel: "API design")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testV24MigratesAdditivelyToTopicContinuitySchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v24")
        let legacyMeeting = Meeting(
            title: "Legacy planning",
            startedAt: Date(timeIntervalSince1970: 1_783_695_600))
        try database.write { db in
            try MeetingRecord(
                legacyMeeting,
                createdAt: legacyMeeting.startedAt,
                updatedAt: legacyMeeting.startedAt)
                .insert(db)
        }

        try migrator.migrate(database)

        try database.read { db in
            XCTAssertEqual(StorageSchema.version, 40)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v40")
            XCTAssertEqual(
                try Set(db.columns(in: "topic").map(\.name)),
                [
                    "id", "preferredLabel", "mergedIntoTopicID", "createdAt",
                    "updatedAt", "deletedAt"
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "topicAlias").map(\.name)),
                [
                    "id", "topicID", "displayLabel", "normalizedAlias", "language",
                    "source", "createdAt", "updatedAt", "deletedAt"
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "topicMeetingEvidence").map(\.name)),
                [
                    "id", "topicID", "aliasID", "meetingID", "segmentID",
                    "sourceTranscriptRevision", "observedLabel", "language", "origin",
                    "resolution", "suggestedTopicID", "similarity",
                    "profileFingerprint", "confirmedAt"
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "topicIdentityEvent").map(\.name)),
                [
                    "id", "kind", "sourceTopicID", "targetTopicID", "occurredAt"
                ])
            XCTAssertEqual(
                Set(try Row.fetchAll(
                    db,
                    sql: "PRAGMA foreign_key_list(topicMeetingEvidence)")
                    .map { $0["table"] as String }),
                ["topic", "topicAlias"])
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM meeting WHERE id = ?",
                    arguments: [legacyMeeting.id.rawValue.uuidString]),
                1)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testGeneratedProposalStaysInertUntilExplicitApplicationConfirmation() async throws {
        let fixture = Self.linkFixture()
        let store = TopicContinuityStoreSpy(link: fixture)
        let proposal = TopicLinkProposal(
            meetingID: fixture.evidence.meetingID,
            segmentID: fixture.evidence.segmentID,
            sourceTranscriptRevision: 0,
            observedLabel: "API design",
            language: "en",
            origin: .generatedSimilarity,
            similarityCandidate: TopicSimilarityCandidate(
                topicID: fixture.topic.id,
                similarity: 0.82,
                profileFingerprint: "semantic-profile-v1"))

        let initialMutations = await store.mutationCount()
        XCTAssertEqual(initialMutations, 0)
        _ = try await FindTopics(store: store).execute("API design")
        let candidateMutations = await store.mutationCount()
        XCTAssertEqual(candidateMutations, 0)

        let confirmed = try await ConfirmTopicLink(store: store).execute(
            ConfirmTopicLinkRequest(
                proposal: proposal,
                selection: .existing(fixture.topic.id)))
        XCTAssertEqual(confirmed, fixture)
        let confirmedMutations = await store.mutationCount()
        XCTAssertEqual(confirmedMutations, 1)
    }

    func testExplicitLinksRetainAmbiguityAndBilingualAliases() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await Self.seedMeeting(
            store,
            texts: [
                "Hablemos del diseño de APIs.",
                "Este otro equipo también dice diseño de APIs.",
                "The API design needs a compatibility plan."
            ])
        let first = try await store.createTopicAndLink(Self.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Diseño de APIs",
            language: "es",
            origin: .manual))
        let second = try await store.createTopicAndLink(Self.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[1],
            label: "Diseno de APIs",
            language: "es",
            origin: .manual))

        let ambiguousCandidates = try await store.topics(
            matchingAlias: "DISEÑO DE APIS")
        XCTAssertEqual(
            Set(ambiguousCandidates.map(\.id)),
            [first.topic.id, second.topic.id])

        let english = try await store.linkTopic(
            Self.proposal(
                meeting: seeded.meeting,
                segment: seeded.segments[2],
                label: "API design",
                language: "EN-us",
                origin: .generatedSimilarity,
                candidateTopicID: first.topic.id),
            to: first.topic.id)
        XCTAssertEqual(english.topic.id, first.topic.id)
        XCTAssertNotEqual(english.observedTopic.id, first.topic.id)
        XCTAssertEqual(english.alias.topicID, english.observedTopic.id)
        XCTAssertEqual(english.alias.language, "en-us")
        XCTAssertEqual(english.evidence.origin, .generatedSimilarity)
        XCTAssertEqual(english.evidence.resolution, .mergedIntoExisting)
        XCTAssertEqual(english.evidence.suggestedTopicID, first.topic.id)
        XCTAssertEqual(english.identityEvent?.kind, .merge)
        let englishCandidates = try await store.topics(matchingAlias: "api design")
        XCTAssertEqual(englishCandidates.map(\.id), [first.topic.id])
        let bilingualEvidence = try await store.topicEvidence(for: first.topic.id)
        XCTAssertEqual(bilingualEvidence.map(\.availability), [.current, .current])

        _ = try await store.splitTopic(
            sourceTopicID: english.observedTopic.id,
            from: first.topic.id)
        let restoredEnglish = try await store.topics(matchingAlias: "api design")
        XCTAssertEqual(restoredEnglish.map(\.id), [english.observedTopic.id])
        let separatedEvidence = try await store.topicEvidence(for: first.topic.id)
        XCTAssertEqual(separatedEvidence.map(\.segmentID), [seeded.segments[0].id])
    }

    func testEvidenceFreshnessIsDerivedWithoutRewritingProvenance() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await Self.seedMeeting(
            store,
            texts: ["El plan de migración queda documentado."])
        let link = try await store.createTopicAndLink(Self.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Plan de migración",
            language: "es",
            origin: .manual))
        let current = try await store.topicEvidence(for: link.topic.id)
        XCTAssertEqual(current.first?.availability, .current)

        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET transcriptRevision = 1 WHERE id = ?",
                arguments: [seeded.meeting.id.rawValue.uuidString])
        }
        let stale = try await store.topicEvidence(for: link.topic.id)
        XCTAssertEqual(stale.first?.availability, .stale)
        XCTAssertEqual(stale.first?.sourceTranscriptRevision, 0)

        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE segment SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), seeded.segments[0].id.uuidString])
        }
        let unavailable = try await store.topicEvidence(for: link.topic.id)
        XCTAssertEqual(unavailable.first?.availability, .unavailable)
        XCTAssertEqual(unavailable.first?.segmentID, seeded.segments[0].id)
    }

    func testActiveCorrectionInvalidatesEvidenceAndRejectsNewConfirmation() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await Self.seedMeeting(
            store,
            texts: ["The Atlas rollout remains on Friday."])
        let first = try await store.createTopicAndLink(Self.proposal(
            meeting: seeded.meeting,
            segment: seeded.segments[0],
            label: "Atlas rollout",
            language: "en",
            origin: .manual))
        let correction = TranscriptCorrectionEvent(
            meetingID: seeded.meeting.id,
            baseTranscriptRevision: seeded.meeting.transcriptRevision,
            targetSegmentIDs: [seeded.segments[0].id],
            kind: .replaceText(text: "The Atlas rollout moved.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_783_695_700))

        _ = try await store.appendTranscriptCorrection(correction)

        let invalidated = try await store.topicEvidence(for: first.topic.id)
        XCTAssertEqual(invalidated.map(\.availability), [.unavailable])
        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.createTopicAndLink(Self.proposal(
                meeting: seeded.meeting,
                segment: seeded.segments[0],
                label: "Friday rollout",
                language: "en",
                origin: .manual))
        }
        let topicCount = try await store.database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM topic")
        }
        XCTAssertEqual(topicCount, 1)
    }

    func testInvalidProposalLeavesNoPartialTopic() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await Self.seedMeeting(store, texts: ["Current source."])
        let stale = TopicLinkProposal(
            meetingID: seeded.meeting.id,
            segmentID: seeded.segments[0].id,
            sourceTranscriptRevision: 1,
            observedLabel: "Architecture",
            language: "en",
            origin: .manual)

        await XCTAssertThrowsTopicContinuityError {
            _ = try await store.createTopicAndLink(stale)
        }
        let counts = try await store.database.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM topic") ?? -1,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM topicAlias") ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM topicMeetingEvidence") ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }
}

extension TopicContinuityTests {
    static func seedMeeting(
        _ store: MeetingStore,
        texts: [String]
    ) async throws -> (meeting: Meeting, segments: [TranscriptSegment]) {
        let meeting = Meeting(title: "Topic planning", startedAt: Date())
        try await store.save(meeting)
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: text,
                language: text.contains(".") ? nil : "en",
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 4),
                isFinal: true)
        }
        try await store.save(segments)
        return (meeting, segments)
    }

    static func proposal(
        meeting: Meeting,
        segment: TranscriptSegment,
        label: String,
        language: String?,
        origin: TopicLinkProposalOrigin,
        candidateTopicID: TopicID? = nil,
        confirmedAt: Date = Date()
    ) -> TopicLinkProposal {
        TopicLinkProposal(
            meetingID: meeting.id,
            segmentID: segment.id,
            sourceTranscriptRevision: meeting.transcriptRevision,
            observedLabel: label,
            language: language,
            origin: origin,
            similarityCandidate: candidateTopicID.map {
                TopicSimilarityCandidate(
                    topicID: $0,
                    similarity: 0.82,
                    profileFingerprint: "semantic-profile-v1")
            },
            confirmedAt: confirmedAt)
    }

    static func topicCounts(_ store: MeetingStore) async throws -> [Int] {
        try await store.database.read { database in
            try ["topic", "topicAlias", "topicMeetingEvidence", "topicIdentityEvent"]
                .map { table in
                    try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM \(table)") ?? -1
                }
        }
    }

    static func linkFixture() -> ConfirmedTopicLink {
        let topic = Topic(preferredLabel: "API design")
        let alias = TopicAlias(
            topicID: topic.id,
            displayLabel: "API design",
            normalizedAlias: "api design",
            language: "en",
            source: .generatedSimilarity)
        let evidence = TopicMeetingEvidence(
            topicID: topic.id,
            aliasID: alias.id,
            meetingID: MeetingID(),
            segmentID: UUID(),
            sourceTranscriptRevision: 0,
            observedLabel: "API design",
            language: "en",
            origin: .generatedSimilarity,
            resolution: .mergedIntoExisting,
            suggestedTopicID: topic.id,
            similarity: 0.82,
            profileFingerprint: "semantic-profile-v1",
            confirmedAt: Date(timeIntervalSince1970: 1_783_695_600),
            availability: .current)
        return ConfirmedTopicLink(
            observedTopic: topic,
            canonicalTopic: topic,
            alias: alias,
            evidence: evidence,
            identityEvent: nil)
    }
}

private actor TopicContinuityStoreSpy: TopicContinuityStore {
    private let link: ConfirmedTopicLink
    private var mutations = 0

    init(link: ConfirmedTopicLink) {
        self.link = link
    }

    func mutationCount() -> Int { mutations }

    func topics(matchingAlias: String) async throws -> [Topic] { [] }

    func createTopicAndLink(
        _ proposal: TopicLinkProposal
    ) async throws -> ConfirmedTopicLink {
        mutations += 1
        return link
    }

    func linkTopic(
        _ proposal: TopicLinkProposal,
        to topicID: TopicID
    ) async throws -> ConfirmedTopicLink {
        mutations += 1
        return link
    }

    func mergeTopics(
        sourceTopicID: TopicID,
        into targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        at timestamp: Date
    ) async throws -> ConfirmedTopicIdentityChange {
        throw TopicContinuitySpyError.unsupported
    }

    func splitTopic(
        sourceTopicID: TopicID,
        from targetTopicID: TopicID,
        eventID: TopicIdentityEventID,
        at timestamp: Date
    ) async throws -> ConfirmedTopicIdentityChange {
        throw TopicContinuitySpyError.unsupported
    }

    func topicEvidence(
        for topicID: TopicID
    ) async throws -> [TopicMeetingEvidence] { [] }
}

private enum TopicContinuitySpyError: Error {
    case unsupported
}

func XCTAssertThrowsTopicContinuityError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
