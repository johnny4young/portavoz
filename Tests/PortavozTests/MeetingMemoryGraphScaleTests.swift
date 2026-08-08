import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

/// GRAPH-6: the scale and correctness gate that decides whether a graph
/// engine is ever needed. A deterministic synthetic corpus — dense repeated
/// topics, same-name people, long supersession chains — is seeded through the
/// real confirmation paths, projected through the real maintenance path, and
/// measured against the interactive budget. The always-on test pins the
/// correctness invariants; the canonical 1k/10k runs are environment-gated
/// like every other release measurement.
final class MeetingMemoryGraphScaleTests: XCTestCase {
    func testEnvironmentRequiresCanonicalScale() throws {
        XCTAssertNil(try MeetingMemoryGraphScaleOptions.environmentOptions([:]))
        let options = try XCTUnwrap(
            MeetingMemoryGraphScaleOptions.environmentOptions([
                "PORTAVOZ_GRAPH_SCALE_BENCHMARK": "1",
                "PORTAVOZ_GRAPH_SCALE_MEETINGS": "1000",
            ]))
        XCTAssertEqual(options.meetingCount, 1_000)
        XCTAssertEqual(options.queryRuns, 30)
        XCTAssertEqual(options.p95BudgetMilliseconds, 250)
    }

    /// Correctness invariants at a small scale that runs on every push:
    /// provenance, rebuild determinism, and correction-awareness are structural
    /// claims, not performance claims, so they never hide behind the env gate.
    func testSmallCorpusHoldsEveryStructuralInvariant() async throws {
        let harness = try await MeetingMemoryGraphScaleHarness.seed(
            options: MeetingMemoryGraphScaleOptions(meetingCount: 120))

        // 1. No edge without provenance: every projected row joins back to
        //    live authority.
        let orphans = try await harness.orphanEdgeCounts()
        XCTAssertEqual(
            orphans.values.reduce(0, +), 0,
            "orphan edges by table: \(orphans)")

        // 2. Correction-awareness: rewriting one meeting's transcript makes
        //    its facts abstain stale while an untouched subject still answers.
        let hot = harness.hotTopicID
        guard case .facts = try await harness.store.decisionHistory(
            DecisionHistoryQuery(topicID: hot))
        else { return XCTFail("the hot topic answers before the correction") }
        try await harness.bumpTranscriptRevision(ofMeeting: harness.hotMeetingID)
        try await harness.project()
        let stale = try await harness.store.decisionHistory(
            DecisionHistoryQuery(topicID: hot))
        XCTAssertEqual(
            stale, .abstained(.staleEvidenceOnly),
            "rewritten evidence must abstain, never serve old text")
        guard case .facts = try await harness.store.decisionHistory(
            DecisionHistoryQuery(topicID: harness.coldTopicID))
        else { return XCTFail("an untouched subject keeps answering") }

        // 3. Every longitudinal job answers source-backed at this scale.
        let report = try await harness.measure(
            queryRuns: 5,
            budgetMilliseconds: 250)
        for lane in report.queries {
            XCTAssertGreaterThan(
                lane.answeredRuns, 0,
                "\(lane.job) never answered")
            XCTAssertLessThan(
                lane.p95Milliseconds, 250,
                "\(lane.job) blew the interactive budget at small scale")
        }

        // 4. The projection is disposable: a full reset under another profile
        //    rebuilds the identical edge sets from authority alone. Edge rows
        //    carry authority identity, so the raw sets are comparable across
        //    profiles — and going through the reset path proves rebuild-from-
        //    zero, not incremental repair. (Returning to the canonical profile
        //    at the same source generation is refused by design — the done
        //    operation is idempotent — so this check runs last.)
        let before = try await harness.rawEdgeSets()
        try await harness.project(fingerprint: String(repeating: "ab", count: 32))
        let after = try await harness.rawEdgeSets()
        XCTAssertEqual(
            before, after,
            "a rebuild from zero must reproduce the same edges")
    }

    /// The canonical measurement. Prints one content-free JSON report per run:
    ///   PORTAVOZ_GRAPH_SCALE_BENCHMARK=1 PORTAVOZ_GRAPH_SCALE_MEETINGS=10000 \
    ///     swift test --filter testCanonicalGraphScaleFromEnvironment
    func testCanonicalGraphScaleFromEnvironment() async throws {
        guard let options = try MeetingMemoryGraphScaleOptions.environmentOptions(
            ProcessInfo.processInfo.environment)
        else {
            throw XCTSkip("set PORTAVOZ_GRAPH_SCALE_BENCHMARK=1 to run")
        }
        let harness = try await MeetingMemoryGraphScaleHarness.seed(options: options)
        let orphans = try await harness.orphanEdgeCounts()
        XCTAssertEqual(orphans.values.reduce(0, +), 0, "\(orphans)")
        let report = try await harness.measure(
            queryRuns: options.queryRuns,
            budgetMilliseconds: options.p95BudgetMilliseconds)

        let payload = try JSONEncoder.graphScale.encode(report)
        print("PORTAVOZ_GRAPH_SCALE_REPORT \(String(decoding: payload, as: UTF8.self))")
        for lane in report.queries {
            XCTAssertLessThan(
                lane.p95Milliseconds,
                Double(options.p95BudgetMilliseconds),
                "\(lane.job) exceeds the interactive budget — the ADR gate opens")
        }
    }
}

struct MeetingMemoryGraphScaleOptions {
    let meetingCount: Int
    var queryRuns = 30
    var p95BudgetMilliseconds = 250

    static func environmentOptions(
        _ environment: [String: String]
    ) throws -> MeetingMemoryGraphScaleOptions? {
        guard environment["PORTAVOZ_GRAPH_SCALE_BENCHMARK"] == "1" else {
            return nil
        }
        let meetings = Int(environment["PORTAVOZ_GRAPH_SCALE_MEETINGS"] ?? "1000") ?? 1_000
        return MeetingMemoryGraphScaleOptions(meetingCount: meetings)
    }
}

/// Content-free measurement report: counts, millis, and bytes only.
struct MeetingMemoryGraphScaleReport: Encodable {
    struct QueryLane: Encodable {
        let job: String
        let answeredRuns: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
    }

    struct RecursiveProbe: Encodable {
        let name: String
        let rows: Int
        let p95Milliseconds: Double
    }

    let schemaVersion: Int
    let fixtureVersion: String
    let meetingCount: Int
    let segmentCount: Int
    let topicCount: Int
    let personCount: Int
    let decisionCount: Int
    let commitmentCount: Int
    let projectionSeconds: Double
    let projectedEdgeCount: Int
    let edgesPerSecond: Double
    let databaseBytes: Int
    let physicalFootprintDeltaBytes: Int
    let queries: [QueryLane]
    let recursiveProbes: [RecursiveProbe]
}

extension JSONEncoder {
    static var graphScale: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Seeds the corpus through the same public confirmation paths the product
/// uses, so the measured cost includes every authority rule underneath.
struct MeetingMemoryGraphScaleHarness {
    let store: MeetingStore
    let options: MeetingMemoryGraphScaleOptions
    let hotTopicID: TopicID
    let coldTopicID: TopicID
    let hotMeetingID: MeetingID
    let hotPersonID: PersonID
    let hotCommitmentID: CommitmentID
    let anchorMeetingID: MeetingID
    private let seededCounts: [String: Int]
    private let projectionSeconds: Double

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    // swiftlint:disable:next function_body_length
    static func seed(
        options: MeetingMemoryGraphScaleOptions
    ) async throws -> MeetingMemoryGraphScaleHarness {
        let store = try MeetingStore.inMemory()
        let meetingCount = options.meetingCount
        // Dense repeated topics: each root topic recurs across ~10 meetings.
        let topicCount = max(2, meetingCount / 10)
        // Same-name people: half the canonical persons share one display name.
        let personCount = max(2, meetingCount / 20)

        var topicIDs: [TopicID] = []
        var personIDs: [PersonID] = []
        var previousDecisionByTopic: [Int: DecisionConfirmation] = [:]
        var hotMeetingID: MeetingID?
        var anchorMeetingID: MeetingID?
        var hotCommitmentID: CommitmentID?
        var commitmentCount = 0

        for index in 0..<meetingCount {
            let startedAt = baseDate.addingTimeInterval(TimeInterval(index) * 3_600)
            let meeting = Meeting(
                title: "Meeting \(index)",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(1_800))
            let speaker = Speaker(meetingID: meeting.id, label: "S1")
            let segment = TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Subject \(index % topicCount) advanced in meeting \(index).",
                language: index.isMultiple(of: 2) ? "en" : "es",
                startTime: 0,
                endTime: 4,
                isFinal: true)
            try await store.save(meeting)
            try await store.save([speaker])
            try await store.save([segment])
            if index == 0 { anchorMeetingID = meeting.id }

            let topicIndex = index % topicCount
            // The hot meeting is the one whose evidence backs the hot topic's
            // CURRENT decision — the latest meeting on topic zero — so the
            // correction test rewrites exactly the transcript that current
            // truth stands on.
            if topicIndex == 0 { hotMeetingID = meeting.id }
            if topicIDs.count == topicIndex {
                let created = try await store.createTopicAndLink(TopicLinkProposal(
                    meetingID: meeting.id,
                    segmentID: segment.id,
                    sourceTranscriptRevision: meeting.transcriptRevision,
                    observedLabel: "subject-\(topicIndex)",
                    language: "en",
                    origin: .manual,
                    confirmedAt: startedAt.addingTimeInterval(10)))
                topicIDs.append(created.topic.id)
            } else {
                _ = try await store.linkTopic(
                    TopicLinkProposal(
                        meetingID: meeting.id,
                        segmentID: segment.id,
                        sourceTranscriptRevision: meeting.transcriptRevision,
                        observedLabel: "subject-\(topicIndex)",
                        language: "en",
                        origin: .manual,
                        confirmedAt: startedAt.addingTimeInterval(10)),
                    to: topicIDs[topicIndex])
            }

            // One confirmed decision per meeting, linked to its subject, and a
            // supersession chain per topic: every later decision on the topic
            // replaces the previous one, so chains reach ~meetings/topics.
            let observationID = SummaryDecisionID()
            let actionItemID = UUID()
            _ = try await store.database.write { [meeting, segment] database in
                try MeetingStore.insertSummarySnapshot(
                    SummaryDraft(
                        meetingID: meeting.id,
                        recipeID: "graph-scale",
                        language: "en",
                        markdown: "## Decisions\n- Option \(index).\n\n"
                            + "## Action Items\n- Deliverable \(index)",
                        actionItems: [ActionItem(
                            id: actionItemID,
                            text: "Deliverable \(index)")],
                        decisionEvidence: [SummaryDecisionEvidence(
                            id: observationID,
                            sectionOrdinal: 0,
                            bulletOrdinal: 0,
                            sourceTranscriptRevision: meeting.transcriptRevision,
                            evidenceSegmentIDs: [segment.id])],
                        actionItemEvidence: [SummaryActionItemEvidence(
                            actionItemID: actionItemID,
                            sourceTranscriptRevision: meeting.transcriptRevision,
                            evidenceSegmentIDs: [segment.id])]),
                    at: startedAt.addingTimeInterval(20),
                    in: database)
            }
            let confirmation = DecisionConfirmation(
                observationID: observationID,
                confirmedAt: startedAt.addingTimeInterval(30))
            _ = try await store.confirmDecision(confirmation)
            _ = try await store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: confirmation.decisionID,
                    topicID: topicIDs[topicIndex],
                    observationID: observationID,
                    confirmedAt: startedAt.addingTimeInterval(40)))
            if let previous = previousDecisionByTopic[topicIndex] {
                _ = try await store.confirmDecisionRelationship(
                    DecisionRelationshipConfirmation(
                        targetDecisionID: previous.decisionID,
                        successorDecisionID: confirmation.decisionID,
                        kind: .supersede,
                        confirmedAt: startedAt.addingTimeInterval(50)))
            }
            previousDecisionByTopic[topicIndex] = confirmation

            // People and commitments: homonyms are distinct canonical persons
            // sharing one display name, and one person accumulates the dense
            // commitment load the personCommitments lane is measured against.
            let personIndex = index % personCount
            if personIDs.count == personIndex {
                let person = try await store.createPersonAndLink(
                    speakerID: speaker.id,
                    preferredName: personIndex.isMultiple(of: 2)
                        ? "Alex García"
                        : "Person \(personIndex)",
                    source: .manualName)
                personIDs.append(person.person.id)
            }
            let commitment = try await store.confirmCommitment(
                CommitmentConfirmation(
                    title: "Deliverable \(index)",
                    assignee: .person(personIDs[personIndex]),
                    origin: .generatedActionItem(actionItemID)),
                at: startedAt.addingTimeInterval(60))
            commitmentCount += 1

            // A blocker every tenth meeting keeps the blocker lane populated;
            // the hot commitment is one that actually has a blocker to serve.
            if index.isMultiple(of: 10) {
                hotCommitmentID = commitment.commitment.id
                _ = try await store.confirmDecisionCommitmentBlocker(
                    DecisionCommitmentBlockerConfirmation(
                        decisionID: confirmation.decisionID,
                        commitmentID: commitment.commitment.id,
                        evidence: DecisionCommitmentBlockerEvidence(
                            meetingID: meeting.id,
                            sourceTranscriptRevision: meeting.transcriptRevision,
                            segmentIDs: [segment.id]),
                        confirmedAt: startedAt.addingTimeInterval(70)))
            }
        }

        // Merged-topic families so root resolution has real depth to chase.
        for index in stride(from: 7, to: topicIDs.count, by: 7) {
            _ = try await store.mergeTopics(
                sourceTopicID: topicIDs[index],
                into: topicIDs[index - 1],
                at: baseDate.addingTimeInterval(
                    TimeInterval(meetingCount) * 3_600 + TimeInterval(index)))
        }

        var harness = MeetingMemoryGraphScaleHarness(
            store: store,
            options: options,
            hotTopicID: topicIDs[0],
            coldTopicID: topicIDs[1],
            hotMeetingID: hotMeetingID ?? MeetingID(),
            hotPersonID: personIDs[0],
            hotCommitmentID: hotCommitmentID ?? CommitmentID(),
            anchorMeetingID: anchorMeetingID ?? MeetingID(),
            seededCounts: [
                "meetings": meetingCount,
                "segments": meetingCount,
                "topics": topicIDs.count,
                "persons": personIDs.count,
                "decisions": meetingCount,
                "commitments": commitmentCount,
            ],
            projectionSeconds: 0)
        let clock = ContinuousClock()
        let started = clock.now
        try await harness.project()
        harness = harness.with(
            projectionSeconds: seconds(clock.now - started))
        return harness
    }

    func project(
        fingerprint: String = MeetingMemoryGraphProjectionProfile.fingerprint
    ) async throws {
        let owner = "graph-scale-\(UUID().uuidString)"
        let timestamp = Date()
        _ = try await store.admitMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint,
            at: timestamp)
        // The production driver heartbeats between batches; the measurement
        // harness instead takes a lease long enough for the largest canonical
        // rebuild, so a lease expiry can never masquerade as a scale result.
        guard let job = try await store.claimMeetingMemoryGraphMaintenance(
            targetFingerprint: fingerprint,
            owner: owner,
            leaseDuration: 7_200,
            at: timestamp)
        else {
            throw StorageError.invalidDerivedMaintenanceJob(
                "graph scale projection could not be claimed")
        }
        _ = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { Date() }).all(job: job, owner: owner, batchSize: 256)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: Date())
    }

    func bumpTranscriptRevision(ofMeeting meetingID: MeetingID) async throws {
        let meetings = try await store.meetings()
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else {
            return
        }
        meeting.transcriptRevision += 1
        try await store.save(meeting)
    }

    /// Raw edge rows per projection table, comparable across profiles because
    /// every column is authority identity.
    func rawEdgeSets() async throws -> [String: Set<String>] {
        let tables = [
            "meetingMemoryGraphMeetingPerson",
            "meetingMemoryGraphMeetingTopic",
            "meetingMemoryGraphMeetingDecision",
            "meetingMemoryGraphMeetingCommitment",
            "meetingMemoryGraphCommitmentPerson",
            "meetingMemoryGraphDecisionTopic",
            "meetingMemoryGraphDecisionCommitmentBlocker",
        ]
        return try await store.database.read { database in
            var sets: [String: Set<String>] = [:]
            for table in tables {
                let rows = try Row.fetchAll(
                    database,
                    sql: "SELECT * FROM \(table)")
                sets[table] = Set(rows.map { row in
                    row.columnNames.sorted().map { name in
                        "\(name)=\(row[name] as String? ?? "-")"
                    }.joined(separator: "|")
                })
            }
            return sets
        }
    }

    /// Every projected edge must join to live authority. Orphans mean the
    /// projection invented topology — the exact failure D270/D271 forbid.
    func orphanEdgeCounts() async throws -> [String: Int] {
        let checks: [(String, String)] = [
            ("meetingMemoryGraphMeetingPerson", """
                SELECT COUNT(*) FROM meetingMemoryGraphMeetingPerson AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM speaker
                    JOIN person ON person.id = speaker.personID
                    WHERE speaker.meetingID = edge.meetingID
                      AND speaker.personID = edge.personID
                      AND speaker.deletedAt IS NULL
                      AND person.deletedAt IS NULL
                )
                """),
            ("meetingMemoryGraphMeetingTopic", """
                SELECT COUNT(*) FROM meetingMemoryGraphMeetingTopic AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM topicMeetingEvidence AS evidence
                    WHERE evidence.meetingID = edge.meetingID
                )
                """),
            ("meetingMemoryGraphMeetingDecision", """
                SELECT COUNT(*) FROM meetingMemoryGraphMeetingDecision AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM decisionContinuitySource AS source
                    WHERE source.meetingID = edge.meetingID
                      AND source.decisionID = edge.decisionID
                )
                """),
            ("meetingMemoryGraphMeetingCommitment", """
                SELECT COUNT(*) FROM meetingMemoryGraphMeetingCommitment AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM commitmentSource AS source
                    WHERE source.meetingID = edge.meetingID
                      AND source.commitmentID = edge.commitmentID
                )
                """),
            ("meetingMemoryGraphDecisionTopic", """
                SELECT COUNT(*) FROM meetingMemoryGraphDecisionTopic AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM decisionTopicLink AS link
                    WHERE link.decisionID = edge.decisionID
                      AND link.status = 'confirmed'
                      AND link.deletedAt IS NULL
                )
                """),
            ("meetingMemoryGraphDecisionCommitmentBlocker", """
                SELECT COUNT(*)
                FROM meetingMemoryGraphDecisionCommitmentBlocker AS edge
                WHERE NOT EXISTS (
                    SELECT 1 FROM decisionCommitmentBlocker AS blocker
                    WHERE blocker.id = edge.blockerID
                      AND blocker.deletedAt IS NULL
                )
                """),
        ]
        return try await store.database.read { database in
            var counts: [String: Int] = [:]
            for (table, sql) in checks {
                counts[table] = try Int.fetchOne(database, sql: sql) ?? -1
            }
            return counts
        }
    }

    // swiftlint:disable:next function_body_length
    func measure(
        queryRuns: Int,
        budgetMilliseconds: Int
    ) async throws -> MeetingMemoryGraphScaleReport {
        let footprintBefore = Self.physicalFootprint()
        var lanes: [MeetingMemoryGraphScaleReport.QueryLane] = []
        let jobs: [(String, () async throws -> MeetingMemoryGraphQueryResult)] = [
            ("decisionHistory", {
                try await store.decisionHistory(
                    DecisionHistoryQuery(topicID: coldTopicID))
            }),
            ("decisionConflicts", {
                try await store.decisionConflicts(
                    DecisionConflictsQuery(topicID: coldTopicID))
            }),
            ("changeSince", {
                try await store.changeSince(ChangeSinceQuery(
                    topicID: coldTopicID,
                    sinceMeetingID: anchorMeetingID))
            }),
            ("firstDiscussion", {
                try await store.topicFirstDiscussion(
                    TopicFirstDiscussionQuery(topicID: coldTopicID))
            }),
            ("personCommitments", {
                try await store.personCommitmentFacts(
                    PersonCommitmentsQuery(personID: hotPersonID))
            }),
            ("commitmentBlockers", {
                try await store.commitmentBlockerFacts(
                    CommitmentBlockerQuery(commitmentID: hotCommitmentID))
            }),
        ]
        for (job, run) in jobs {
            var samples: [Double] = []
            var answered = 0
            let clock = ContinuousClock()
            for _ in 0..<queryRuns {
                let started = clock.now
                let result = try await run()
                samples.append(Self.seconds(clock.now - started) * 1_000)
                if case .facts = result { answered += 1 }
            }
            samples.sort()
            lanes.append(MeetingMemoryGraphScaleReport.QueryLane(
                job: job,
                answeredRuns: answered,
                p50Milliseconds: Self.percentile(samples, 0.50),
                p95Milliseconds: Self.percentile(samples, 0.95)))
        }

        // The explicit recursive-CTE measurement the ticket demands: family
        // and chain traversal expressed as SQL recursion, timed at scale.
        var probes: [MeetingMemoryGraphScaleReport.RecursiveProbe] = []
        let cteProbes: [(String, String, StatementArguments)] = [
            ("topicFamilyRoots", """
                WITH RECURSIVE family(id, rootID) AS (
                    SELECT id, id FROM topic
                    WHERE mergedIntoTopicID IS NULL AND deletedAt IS NULL
                    UNION ALL
                    SELECT topic.id, family.rootID
                    FROM topic
                    JOIN family ON topic.mergedIntoTopicID = family.id
                    WHERE topic.deletedAt IS NULL
                )
                SELECT COUNT(*) FROM family
                """, []),
            ("supersessionChain", """
                WITH RECURSIVE chain(decisionID, depth) AS (
                    SELECT ?, 0
                    UNION ALL
                    SELECT event.relatedDecisionID, chain.depth + 1
                    FROM decisionContinuityEvent AS event
                    JOIN chain ON event.decisionID = chain.decisionID
                    WHERE event.kind IN ('supersede', 'reverse')
                      AND event.relatedDecisionID IS NOT NULL
                )
                SELECT COUNT(*) FROM chain
                """, [try await oldestDecisionKey()]),
        ]
        for (name, sql, arguments) in cteProbes {
            var samples: [Double] = []
            var rows = 0
            let clock = ContinuousClock()
            for _ in 0..<max(queryRuns, 5) {
                let started = clock.now
                rows = try await store.database.read { database in
                    try Int.fetchOne(database, sql: sql, arguments: arguments) ?? 0
                }
                samples.append(Self.seconds(clock.now - started) * 1_000)
            }
            samples.sort()
            probes.append(MeetingMemoryGraphScaleReport.RecursiveProbe(
                name: name,
                rows: rows,
                p95Milliseconds: Self.percentile(samples, 0.95)))
        }

        let databaseBytes = try await store.database.read { database in
            let pageCount = try Int.fetchOne(database, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int.fetchOne(database, sql: "PRAGMA page_size") ?? 0
            return pageCount * pageSize
        }
        let edgeCount = try await store.database.read { database in
            try [
                "meetingMemoryGraphMeetingPerson",
                "meetingMemoryGraphMeetingTopic",
                "meetingMemoryGraphMeetingDecision",
                "meetingMemoryGraphMeetingCommitment",
                "meetingMemoryGraphCommitmentPerson",
                "meetingMemoryGraphDecisionTopic",
                "meetingMemoryGraphDecisionCommitmentBlocker",
            ].reduce(0) { total, table in
                total + (try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            }
        }
        let footprintAfter = Self.physicalFootprint()
        return MeetingMemoryGraphScaleReport(
            schemaVersion: 1,
            fixtureVersion: "synthetic-graph-scale-v1",
            meetingCount: seededCounts["meetings"] ?? 0,
            segmentCount: seededCounts["segments"] ?? 0,
            topicCount: seededCounts["topics"] ?? 0,
            personCount: seededCounts["persons"] ?? 0,
            decisionCount: seededCounts["decisions"] ?? 0,
            commitmentCount: seededCounts["commitments"] ?? 0,
            projectionSeconds: projectionSeconds,
            projectedEdgeCount: edgeCount,
            edgesPerSecond: projectionSeconds > 0
                ? Double(edgeCount) / projectionSeconds
                : 0,
            databaseBytes: databaseBytes,
            physicalFootprintDeltaBytes: max(0, footprintAfter - footprintBefore),
            queries: lanes,
            recursiveProbes: probes)
    }

    private func oldestDecisionKey() async throws -> String {
        try await store.database.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM decisionContinuity
                    ORDER BY createdAt, id LIMIT 1
                    """) ?? ""
        }
    }

    private func with(projectionSeconds: Double) -> MeetingMemoryGraphScaleHarness {
        MeetingMemoryGraphScaleHarness(
            store: store,
            options: options,
            hotTopicID: hotTopicID,
            coldTopicID: coldTopicID,
            hotMeetingID: hotMeetingID,
            hotPersonID: hotPersonID,
            hotCommitmentID: hotCommitmentID,
            anchorMeetingID: anchorMeetingID,
            seededCounts: seededCounts,
            projectionSeconds: projectionSeconds)
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(rank, sorted.count - 1)]
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    /// task-level physical footprint, the same metric Activity Monitor shows.
    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }
}
