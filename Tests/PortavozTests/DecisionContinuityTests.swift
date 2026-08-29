import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class DecisionContinuityTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_786_000_000)

    func testV25MigratesAdditivelyToDecisionContinuitySchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v25")
        let legacyMeeting = Meeting(
            title: "Legacy planning",
            startedAt: baseDate)
        try database.write { db in
            try MeetingRecord(
                legacyMeeting,
                createdAt: legacyMeeting.startedAt,
                updatedAt: legacyMeeting.startedAt)
                .insert(db)
        }

        try migrator.migrate(database)

        try database.read { db in
            XCTAssertEqual(StorageSchema.version, 46)
            XCTAssertEqual(
                try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v46")
            XCTAssertEqual(
                try Set(db.columns(in: "decisionContinuity").map(\.name)),
                ["id", "statement", "status", "createdAt", "updatedAt", "deletedAt"])
            XCTAssertEqual(
                try Set(db.columns(in: "decisionContinuitySource").map(\.name)),
                [
                    "id", "decisionID", "summaryDecisionID", "summaryID", "meetingID",
                    "observedStatement", "sourceTranscriptRevision", "observedAt", "linkedAt"
                ])
            XCTAssertEqual(
                try Set(db.columns(in: "decisionContinuityEvidenceSegment").map(\.name)),
                ["sourceID", "segmentID", "ordinal"])
            XCTAssertEqual(
                try Set(db.columns(in: "decisionContinuityEvent").map(\.name)),
                [
                    "id", "decisionID", "kind", "sourceID", "relatedDecisionID",
                    "occurredAt"
                ])
            XCTAssertEqual(
                try Row.fetchAll(
                    db,
                    sql: "PRAGMA index_info(decisionContinuitySource_on_decision)")
                    .map { $0["name"] as String },
                ["decisionID", "linkedAt", "observedAt", "meetingID", "id"])
            XCTAssertEqual(
                Set(try Row.fetchAll(
                    db,
                    sql: "PRAGMA foreign_key_list(decisionContinuitySource)")
                    .map { $0["table"] as String }),
                ["decisionContinuity"])
            XCTAssertEqual(
                Set(try Row.fetchAll(
                    db,
                    sql: "PRAGMA foreign_key_list(decisionContinuityEvidenceSegment)")
                    .map { $0["table"] as String }),
                ["decisionContinuitySource"])
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM meeting WHERE id = ?",
                    arguments: [legacyMeeting.id.rawValue.uuidString]),
                1)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testGeneratedObservationStaysInertUntilExplicitConfirmation() async throws {
        let fixture = try Self.applicationFixture(at: baseDate)
        let store = DecisionContinuityStoreSpy(
            observation: fixture.observation,
            continuity: fixture.continuity)

        let observed = try await LoadDecisionObservation(store: store).execute(
            fixture.observation.id)
        XCTAssertEqual(observed.status, .observed)
        let initialMutations = await store.mutationCount()
        XCTAssertEqual(initialMutations, 0)

        let confirmation = DecisionConfirmation(
            decisionID: fixture.continuity.decision.id,
            sourceID: fixture.continuity.sources[0].id,
            eventID: fixture.continuity.events[0].id,
            observationID: fixture.observation.id,
            confirmedAt: baseDate)
        let confirmed = try await ConfirmObservedDecision(store: store).execute(
            confirmation)

        XCTAssertEqual(confirmed, fixture.continuity)
        let confirmedMutations = await store.mutationCount()
        XCTAssertEqual(confirmedMutations, 1)
    }

    func testObservationResolvesExactRenderedStatementAndOrderedEvidence() async throws {
        let store = try MeetingStore.inMemory()
        let seeded = try await Self.seedObservation(
            store,
            statement: "Ship the API compatibility layer.",
            evidenceTexts: ["We will ship it.", "Compatibility is required."],
            startedAt: baseDate)

        let observation = try await store.decisionObservation(
            for: seeded.observationID)

        XCTAssertEqual(observation.id, seeded.observationID)
        XCTAssertEqual(observation.meetingID, seeded.meeting.id)
        XCTAssertEqual(observation.statement, seeded.statement)
        XCTAssertEqual(observation.status, .observed)
        XCTAssertEqual(observation.availability, .current)
        XCTAssertEqual(
            observation.evidence.map(\.segmentID),
            seeded.segments.map(\.id))
        XCTAssertEqual(observation.evidence.map(\.ordinal), [0, 1])
        let continuityRows = try await Self.decisionCounts(store)
        XCTAssertEqual(continuityRows, [0, 0, 0, 0])
    }

    func testExplicitConfirmationAndLaterSourceRetainEveryMeeting() async throws {
        let store = try MeetingStore.inMemory()
        let first = try await Self.seedObservation(
            store,
            statement: "Adopt the compatibility layer.",
            evidenceTexts: ["The team chose the compatibility layer."],
            startedAt: baseDate)
        let second = try await Self.seedObservation(
            store,
            statement: "The compatibility layer remains the plan.",
            evidenceTexts: ["We reaffirmed the compatibility layer."],
            startedAt: baseDate.addingTimeInterval(60))
        let confirmation = DecisionConfirmation(
            observationID: first.observationID,
            confirmedAt: baseDate.addingTimeInterval(120))

        let initial = try await store.confirmDecision(confirmation)
        XCTAssertEqual(initial.decision.status, .confirmed)
        XCTAssertEqual(initial.decision.statement, first.statement)
        XCTAssertEqual(initial.sources.map(\.meetingID), [first.meeting.id])
        XCTAssertEqual(initial.events.map(\.kind), [.confirm])

        let linked = try await store.linkDecisionSource(DecisionSourceConfirmation(
            decisionID: confirmation.decisionID,
            observationID: second.observationID,
            confirmedAt: baseDate.addingTimeInterval(180)))

        XCTAssertEqual(linked.decision, initial.decision)
        XCTAssertEqual(
            linked.sources.map(\.meetingID),
            [first.meeting.id, second.meeting.id])
        XCTAssertEqual(
            linked.sources.flatMap { $0.evidence.map(\.segmentID) },
            [first.segments[0].id, second.segments[0].id])
        XCTAssertEqual(linked.events, initial.events)
        let counts = try await Self.decisionCounts(store)
        XCTAssertEqual(counts, [1, 2, 2, 1])
    }

    func testSupersedeAndReverseNameTheConfirmedSuccessor() async throws {
        for kind in [DecisionRelationshipKind.supersede, .reverse] {
            let store = try MeetingStore.inMemory()
            let older = try await Self.seedObservation(
                store,
                statement: "Use the legacy API.",
                evidenceTexts: ["The legacy API was selected."],
                startedAt: baseDate)
            let newer = try await Self.seedObservation(
                store,
                statement: "Use the new API.",
                evidenceTexts: ["The new API was selected."],
                startedAt: baseDate.addingTimeInterval(60))
            let olderConfirmation = DecisionConfirmation(
                observationID: older.observationID,
                confirmedAt: baseDate.addingTimeInterval(120))
            let newerConfirmation = DecisionConfirmation(
                observationID: newer.observationID,
                confirmedAt: baseDate.addingTimeInterval(180))
            _ = try await store.confirmDecision(olderConfirmation)
            let successor = try await store.confirmDecision(newerConfirmation)

            let target = try await store.confirmDecisionRelationship(
                DecisionRelationshipConfirmation(
                    targetDecisionID: olderConfirmation.decisionID,
                    successorDecisionID: newerConfirmation.decisionID,
                    kind: kind,
                    confirmedAt: baseDate.addingTimeInterval(240)))

            XCTAssertEqual(
                target.decision.status,
                kind == .supersede ? .superseded : .reversed)
            XCTAssertEqual(target.events.map(\.kind), [.confirm, kind.eventKind])
            XCTAssertEqual(target.events.last?.relatedDecisionID, successor.decision.id)
            let currentSuccessor = try await store.decisionContinuity(
                for: successor.decision.id)
            XCTAssertEqual(currentSuccessor.decision.status, .confirmed)
        }
    }
}

extension DecisionContinuityTests {
    struct SeededObservation {
        let meeting: Meeting
        let segments: [TranscriptSegment]
        let observationID: SummaryDecisionID
        let statement: String
    }

    static func seedObservation(
        _ store: MeetingStore,
        statement: String,
        evidenceTexts: [String],
        startedAt: Date,
        summaryCreatedAt: Date? = nil
    ) async throws -> SeededObservation {
        let meeting = Meeting(title: "Decision meeting", startedAt: startedAt)
        try await store.save(meeting)
        let segments = evidenceTexts.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: text,
                language: "en",
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 4),
                isFinal: true)
        }
        try await store.save(segments)
        let observationID = SummaryDecisionID()
        let draft = SummaryDraft(
            meetingID: meeting.id,
            recipeID: "decision-continuity-test",
            language: "en",
            markdown: "# Summary\n\n## Decisions\n- \(statement)",
            actionItems: [],
            decisionEvidence: [SummaryDecisionEvidence(
                id: observationID,
                sectionOrdinal: 0,
                bulletOrdinal: 0,
                sourceTranscriptRevision: meeting.transcriptRevision,
                evidenceSegmentIDs: segments.map(\.id))])
        if let summaryCreatedAt {
            _ = try await store.database.write { database in
                try MeetingStore.insertSummarySnapshot(
                    draft,
                    at: summaryCreatedAt,
                    in: database)
            }
        } else {
            _ = try await store.saveSummary(draft)
        }
        return SeededObservation(
            meeting: meeting,
            segments: segments,
            observationID: observationID,
            statement: statement)
    }

    static func decisionCounts(_ store: MeetingStore) async throws -> [Int] {
        try await store.database.read { database in
            try [
                "decisionContinuity", "decisionContinuitySource",
                "decisionContinuityEvidenceSegment", "decisionContinuityEvent"
            ].map { table in
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
    }

    static func applicationFixture(
        at timestamp: Date
    ) throws -> (observation: DecisionObservation, continuity: DecisionContinuity) {
        let observation = DecisionObservation(
            id: SummaryDecisionID(),
            summaryID: SummaryID(),
            meetingID: MeetingID(),
            statement: "Adopt the compatibility layer.",
            sourceTranscriptRevision: 0,
            observedAt: timestamp,
            evidence: [DecisionEvidenceSegment(segmentID: UUID(), ordinal: 0)],
            availability: .current)
        let decisionID = DecisionID()
        let sourceID = DecisionSourceID()
        let event = DecisionEvent(
            decisionID: decisionID,
            kind: .confirm,
            sourceID: sourceID,
            occurredAt: timestamp)
        let decision = try DecisionContinuityPolicy.projectedDecision(
            id: decisionID,
            statement: observation.statement,
            events: [event])
        let source = DecisionSource(
            id: sourceID,
            decisionID: decisionID,
            observationID: observation.id,
            summaryID: observation.summaryID,
            meetingID: observation.meetingID,
            observedStatement: observation.statement,
            sourceTranscriptRevision: observation.sourceTranscriptRevision,
            observedAt: timestamp,
            linkedAt: timestamp,
            evidence: observation.evidence,
            availability: .current)
        return (observation, try DecisionContinuity(
            decision: decision,
            sources: [source],
            events: [event]))
    }
}

private actor DecisionContinuityStoreSpy: DecisionContinuityStore {
    private let observation: DecisionObservation
    private let continuity: DecisionContinuity
    private var mutations = 0

    init(observation: DecisionObservation, continuity: DecisionContinuity) {
        self.observation = observation
        self.continuity = continuity
    }

    func mutationCount() -> Int { mutations }

    func decisionObservation(
        for observationID: SummaryDecisionID
    ) async throws -> DecisionObservation { observation }

    func confirmDecision(
        _ confirmation: DecisionConfirmation
    ) async throws -> DecisionContinuity {
        mutations += 1
        return continuity
    }

    func linkDecisionSource(
        _ confirmation: DecisionSourceConfirmation
    ) async throws -> DecisionContinuity {
        mutations += 1
        return continuity
    }

    func confirmDecisionRelationship(
        _ confirmation: DecisionRelationshipConfirmation
    ) async throws -> DecisionContinuity {
        mutations += 1
        return continuity
    }

    func decisionContinuity(
        for decisionID: DecisionID
    ) async throws -> DecisionContinuity { continuity }
}
