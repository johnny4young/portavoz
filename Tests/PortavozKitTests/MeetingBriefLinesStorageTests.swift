import GRDB
import PortavozCore
@testable import StorageKit
import XCTest

final class MeetingBriefLinesStorageTests: XCTestCase {
    private var store: MeetingStore!
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let eventID = "event-weekly"
    private var eventStart: Date { base.addingTimeInterval(7 * 86_400) }

    override func setUpWithError() throws {
        store = try MeetingStore.inMemory()
    }

    private struct Fixture {
        var meeting: Meeting
        let me: Speaker
        let marta: Speaker
        let segments: [TranscriptSegment]
    }

    private let texts = [
        "We should ship the new onboarding flow before the quarter ends",
        "I will write the migration plan and share it tomorrow morning",
        "Which retention policy applies to the old recordings",
        "ok fine",
        "Budget numbers still look wrong to me",
        "Let me also confirm the vendor contract renewal date today",
    ]

    /// Marta speaks 0–40, 150–200 and 210–215; you 40–100, 200–205 and 300–320.
    private func seed(title: String = "Weekly sync") async throws -> Fixture {
        let meeting = Meeting(title: title, startedAt: base, endedAt: base.addingTimeInterval(600))
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let marta = Speaker(meetingID: meeting.id, label: "S1", displayName: "Marta")
        try await store.save([me, marta])
        let turns: [(Speaker, TimeInterval, TimeInterval)] = [
            (marta, 0, 40), (me, 40, 100), (marta, 150, 200), (me, 200, 205), (marta, 210, 215), (me, 300, 320),
        ]
        let segments = zip(turns, texts).map { turn, text in
            TranscriptSegment(
                meetingID: meeting.id, speakerID: turn.0.id, channel: turn.0.isMe ? .microphone : .system,
                text: text, startTime: turn.1, endTime: turn.2, isFinal: true)
        }
        try await store.save(segments)
        return Fixture(meeting: meeting, me: me, marta: marta, segments: segments)
    }

    private func record(_ fixture: Fixture, event: String? = nil) async throws {
        try await store.recordMeetingBriefSource(
            eventID: event ?? eventID, eventStartAt: eventStart, sourceMeetingID: fixture.meeting.id, at: base)
    }

    private func occurrence(_ event: String? = nil) -> MeetingBriefLines.Occurrence {
        MeetingBriefLines.Occurrence(eventID: event ?? eventID, startAt: eventStart)
    }

    private func read(_ event: String? = nil) async throws -> MeetingBriefLines {
        let lines = try await store.meetingBriefLines(for: occurrence(event))
        return try XCTUnwrap(lines)
    }

    private func builtAt(_ event: String? = nil) async throws -> Date? {
        try await store.database.read { [eventID] db in
            try Date.fetchOne(
                db, sql: "SELECT linesBuiltAt FROM meetingBriefSource WHERE eventID = ?",
                arguments: [event ?? eventID])
        }
    }

    private func count(_ table: String) async throws -> Int {
        try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func saveSummary(
        _ fixture: Fixture, items: [(item: ActionItem, evidence: Int?)], recipe: String = Recipe.general.id
    ) async throws {
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: fixture.meeting.id, recipeID: recipe, language: "en", markdown: "Summary.",
            actionItems: items.map(\.item),
            actionItemEvidence: items.compactMap { entry in
                entry.evidence.map {
                    SummaryActionItemEvidence(
                        actionItemID: entry.item.id, evidenceSegmentIDs: [fixture.segments[$0].id])
                }
            }))
    }

    func testMigrationCreatesTheCacheTables() throws {
        let database = try DatabaseQueue()
        try StorageSchema.migrator().migrate(database)
        try database.read { db in
            XCTAssertTrue(try db.tableExists("meetingBriefSource"))
            XCTAssertTrue(try db.tableExists("meetingBriefLine"))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC"),
                "v\(StorageSchema.version)")
        }
        XCTAssertGreaterThanOrEqual(StorageSchema.version, 62)
    }

    func testQuotesFillTwoLinesPerPersonInTimeOrder() async throws {
        let fixture = try await seed()
        try await record(fixture)

        let lines = try await read()

        XCTAssertEqual(lines.occurrence, occurrence())
        XCTAssertEqual(lines.sourceMeetingID, fixture.meeting.id)
        XCTAssertEqual(lines.preparedAt, base)
        XCTAssertEqual(lines.people.map(\.speakerID), [fixture.marta.id, fixture.me.id])
        XCTAssertEqual(lines.people.map(\.displayName), ["Marta", nil])
        XCTAssertEqual(lines.people.map(\.isMe), [false, true])
        XCTAssertEqual(lines.people[0].lines.map(\.text), [texts[0], texts[2]])
        XCTAssertEqual(lines.people[0].lines.map(\.time), [0, 150])
        XCTAssertEqual(lines.people[0].lines.map(\.segmentID), [fixture.segments[0].id, fixture.segments[2].id])
        XCTAssertEqual(lines.people[1].lines.map(\.text), [texts[1], texts[5]])
        XCTAssertTrue(lines.people.flatMap(\.lines).allSatisfy { $0.kind == .quote && $0.status == .said })
        let absent = try await store.meetingBriefLines(for: occurrence("unknown"))
        XCTAssertNil(absent)
        let empty = try await store.meetingBriefLines(for: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testLongQuotesAreCutAtAWordBoundary() {
        let long = Array(repeating: "palabra", count: 40).joined(separator: " ")
        let quote = MeetingBriefLines.quote(long)
        XCTAssertEqual(quote?.hasSuffix("palabra…"), true)
        XCTAssertLessThanOrEqual(quote?.count ?? 0, MeetingBriefLines.maximumQuoteLength + 1)
        XCTAssertNil(MeetingBriefLines.quote("three short words"))
        XCTAssertEqual(MeetingBriefLines.quote("  four  words are enough "), "four words are enough")
    }

    func testCommitmentsAndQuestionsComeBeforeQuotes() async throws {
        let fixture = try await seed()
        let mine = ActionItem(text: "Write the migration plan", ownerSpeakerID: fixture.me.id)
        let done = ActionItem(text: "Ship onboarding", ownerSpeakerID: fixture.marta.id)
        let dismissed = ActionItem(text: "Rename the product", ownerSpeakerID: fixture.marta.id)
        let unconfirmed = ActionItem(text: "Fix the budget numbers", ownerSpeakerID: fixture.marta.id)
        let unowned = ActionItem(text: "Somebody books a room")
        try await saveSummary(fixture, items: [
            (mine, 1), (done, 0), (dismissed, 0), (unconfirmed, 4), (unowned, nil),
        ])
        let due = base.addingTimeInterval(86_400)
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(title: mine.text, dueAt: due, origin: .generatedActionItem(mine.id)),
            at: base)
        for (item, transition) in [(done, CommitmentTransition.complete), (dismissed, .dismiss)] {
            let envelope = try await store.confirmCommitment(
                CommitmentConfirmation(title: item.text, origin: .generatedActionItem(item.id)), at: base)
            _ = try await store.applyCommitmentTransition(
                transition, to: envelope.commitment.id, at: base.addingTimeInterval(1))
        }
        try await saveSummary(fixture, items: [
            (ActionItem(text: "rename the product", ownerSpeakerID: fixture.marta.id), 0),
        ], recipe: "another-recipe")
        let topic = Topic(preferredLabel: "Retention")
        try await store.database.write { [base] db in
            try TopicRecord(topic, createdAt: base, updatedAt: base).insert(db)
        }
        let evidence = MeetingQuestionEvidence(
            meetingID: fixture.meeting.id, sourceTranscriptRevision: fixture.meeting.transcriptRevision,
            segmentIDs: [fixture.segments[2].id])
        let question = try await store.confirmMeetingQuestion(MeetingQuestionConfirmation(
            topicID: topic.id, text: "Which retention policy applies?", evidence: evidence, confirmedAt: base))
        try await record(fixture)

        var lines = try await read()

        XCTAssertEqual(lines.people[0].lines, [
            .init(kind: .commitment, text: "Ship onboarding", segmentID: fixture.segments[0].id,
                  time: 0, status: .closed),
            .init(kind: .question, text: "Which retention policy applies?",
                  segmentID: fixture.segments[2].id, time: 150, status: .unresolved),
            .init(kind: .commitment, text: "Fix the budget numbers", segmentID: fixture.segments[4].id,
                  time: 210, status: .open(due: nil)),
        ])
        XCTAssertEqual(lines.people[1].lines, [
            .init(kind: .commitment, text: "Write the migration plan", segmentID: fixture.segments[1].id,
                  time: 40, status: .open(due: due)),
            .init(kind: .quote, text: texts[5], segmentID: fixture.segments[5].id, time: 300, status: .said),
        ])

        _ = try await store.applyMeetingQuestionTransition(MeetingQuestionTransitionConfirmation(
            questionID: question.question.id, transition: .resolve, evidence: evidence,
            confirmedAt: base.addingTimeInterval(5)))
        try await store.setActionItem(unconfirmed.id, done: true)
        let cleared = try await builtAt()
        XCTAssertNil(cleared)
        lines = try await read()
        XCTAssertEqual(lines.people[0].lines.map(\.status), [.closed, .closed, .closed])

        _ = try await store.applyMeetingQuestionTransition(MeetingQuestionTransitionConfirmation(
            questionID: question.question.id, transition: .reopen, evidence: evidence,
            confirmedAt: base.addingTimeInterval(10)))
        _ = try await store.applyMeetingQuestionTransition(MeetingQuestionTransitionConfirmation(
            questionID: question.question.id, transition: .dismiss, evidence: evidence,
            confirmedAt: base.addingTimeInterval(15)))
        lines = try await read()
        XCTAssertEqual(lines.people[0].lines.map(\.kind), [.commitment, .commitment])
    }

    func testSelectionNeedsNoDatabase() {
        let ana = SpeakerID(), ben = SpeakerID()
        let segment = UUID()
        let commitment = MeetingBriefLines.Line(
            kind: .commitment, text: "Send the plan", segmentID: segment, time: 50, status: .open(due: nil))
        let selected = MeetingBriefLines.select(
            speakers: [ana, ben],
            tracked: [ana: [commitment]],
            spoken: [
                ana: [
                    .init(segmentID: segment, text: "I will send the plan on Friday", start: 50),
                    .init(segmentID: UUID(), text: "The vendor answered us last week", start: 10),
                    .init(segmentID: UUID(), text: "A much longer line that still reads as a quote", start: 90),
                ],
                ben: [.init(segmentID: UUID(), text: "ok", start: 5)],
            ])

        XCTAssertEqual(selected.map(\.speakerID), [ana], "a person without lines is absent")
        XCTAssertEqual(selected[0].lines.map(\.kind), [.commitment, .quote])
        XCTAssertEqual(selected[0].lines.last?.time, 90, "the longest unused line fills the quote")
    }

    func testAPersonKeepsAtMostThreeLinesAndPendingOnesFirst() async throws {
        let fixture = try await seed()
        let items = ["One", "Two", "Three", "Four"].enumerated().map { index, text in
            ActionItem(text: text, ownerSpeakerID: fixture.me.id, isDone: index == 0)
        }
        try await saveSummary(fixture, items: items.map { ($0, nil) })
        try await saveSummary(fixture, items: [
            (ActionItem(text: " two ", ownerSpeakerID: fixture.me.id), nil),
        ], recipe: "another-recipe")
        try await record(fixture)

        let mine = try await read().people[1].lines

        XCTAssertEqual(mine.map(\.text), ["Two", "Three", "Four"])
        XCTAssertTrue(mine.allSatisfy { $0.segmentID == nil && $0.time == 0 && $0.status == .open(due: nil) })

        try await saveSummary(fixture, items: [(ActionItem(text: "Newer", ownerSpeakerID: fixture.me.id), nil)])
        let regenerated = try await read().people[1].lines
        XCTAssertEqual(regenerated.filter { $0.kind == .commitment }.map(\.text), ["two", "Newer"])
    }

    func testOnlyTheSixMostTalkativePeopleAreKept() async throws {
        let meeting = Meeting(title: "All hands", startedAt: base, endedAt: base.addingTimeInterval(600))
        try await store.save(meeting)
        let speakers = (0..<7).map { Speaker(meetingID: meeting.id, label: "S\($0)") }
        try await store.save(speakers)
        try await store.save(speakers.enumerated().map { index, speaker in
            TranscriptSegment(
                meetingID: meeting.id, speakerID: speaker.id, channel: .system,
                text: "this is what speaker \(index) said", startTime: Double(index) * 100,
                endTime: Double(index) * 100 + Double(index + 1) * 10, isFinal: true)
        })
        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: meeting.id, at: base)

        let people = try await read().people

        XCTAssertEqual(people.map(\.speakerID), speakers.dropFirst().reversed().map(\.id))
    }

    func testResolvingACommitmentElsewhereWakesTheOccurrencesObservers() async throws {
        let fixture = try await seed()
        let item = ActionItem(text: "Write the migration plan", ownerSpeakerID: fixture.me.id)
        try await saveSummary(fixture, items: [(item, 1)])
        var states = store.observeMeetingBriefSource(for: occurrence()).makeAsyncIterator()
        let none = try await states.next()
        XCTAssertEqual(none, .some(nil), "no source before the first preparation")

        try await record(fixture)
        let built = try await states.next()
        XCTAssertEqual(built??.sourceMeetingID, fixture.meeting.id)
        XCTAssertEqual(built??.linesBuiltAt, base)

        try await record(fixture, event: "another-event")
        try await store.setActionItem(item.id, done: true)
        let cleared = try await states.next()
        XCTAssertEqual(cleared??.sourceMeetingID, fixture.meeting.id)
        XCTAssertNil(cleared??.linesBuiltAt, "another occurrence's write is not an emission; the clear is")
        _ = try await read()
        let rebuilt = try await states.next()
        XCTAssertNotNil(rebuilt??.linesBuiltAt, "the read rebuilds, then the value settles")
    }

    func testASourceWithoutLinesIsBuiltOnce() async throws {
        let meeting = Meeting(title: "Short", startedAt: base, endedAt: base.addingTimeInterval(60))
        try await store.save(meeting)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        try await store.save([me])
        try await store.save([TranscriptSegment(
            meetingID: meeting.id, speakerID: me.id, channel: .microphone,
            text: "ok", startTime: 0, endTime: 1, isFinal: true)])
        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: meeting.id, at: base)
        let built = try await builtAt()

        let first = try await read()
        let second = try await read()
        let reread = try await builtAt()

        XCTAssertEqual(built, base, "preparing the brief builds the lines")
        XCTAssertTrue(first.people.isEmpty)
        XCTAssertEqual(second, first)
        XCTAssertEqual(reread, built)

        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: meeting.id,
            at: base.addingTimeInterval(60))
        let reprepared = try await builtAt()
        XCTAssertEqual(reprepared, built, "preparing again with the same source keeps current lines")
    }

    func testTranscriptChangesClearTheLinesAndTheNextReadRebuilds() async throws {
        let fixture = try await seed()
        try await record(fixture)
        try await record(fixture, event: "event-other")
        _ = try await read()
        _ = try await read("event-other")

        _ = try await store.appendTranscriptCorrections([
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id, baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[0].id],
                kind: .replaceText(text: "We must ship the new onboarding flow before the quarter ends", language: nil),
                sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)),
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id, baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[5].id], kind: .changeSpeaker(fixture.marta.id),
                sourceDeviceID: UUID(), createdAt: Date(timeIntervalSince1970: 10)),
        ])
        let cleared = try await builtAt()
        let lineCount = try await count("meetingBriefLine")
        XCTAssertNil(cleared)
        XCTAssertEqual(lineCount, 0)
        let corrected = try await store.meetingBriefLines(for: [occurrence(), occurrence("event-other")])
        let weekly = try XCTUnwrap(corrected[occurrence()])
        XCTAssertEqual(weekly.people, corrected[occurrence("event-other")]?.people)
        XCTAssertEqual(weekly.people[0].lines.first?.text.hasPrefix("We must ship"), true)
        XCTAssertEqual(weekly.people[0].lines.map(\.time), [0, 300])
        XCTAssertEqual(weekly.people[1].lines.map(\.text), [texts[1]])

        var edited = fixture.segments[1]
        edited.text = "I will write the rollback plan and share it tomorrow morning"
        try await store.save([edited])
        let editedLines = try await read()
        XCTAssertEqual(editedLines.people[1].lines.map(\.text), [edited.text])

        let s2 = Speaker(meetingID: fixture.meeting.id, label: "S2")
        try await store.applyRefinedCast(
            for: fixture.meeting.id, expectedTranscriptRevision: fixture.meeting.transcriptRevision,
            language: "es", speakers: [fixture.me, s2],
            segments: [TranscriptSegment(
                meetingID: fixture.meeting.id, speakerID: s2.id, channel: .system,
                text: "esto es lo que dijo otra persona", startTime: 0, endTime: 30, isFinal: true)])
        let refined = try await read()
        XCTAssertEqual(refined.people.map(\.speakerID), [s2.id])
        XCTAssertEqual(refined.people[0].lines.map(\.text), ["esto es lo que dijo otra persona"])
    }

    func testARenamedSpeakerReadsWithTheNewName() async throws {
        let fixture = try await seed()
        try await record(fixture)
        _ = try await read()
        var renamed = fixture.marta
        renamed.displayName = "Marta Ruiz"
        try await store.save([renamed])

        let lines = try await read()

        XCTAssertEqual(lines.people[0].displayName, "Marta Ruiz")
    }

    func testRenamingOrDeletingTheSourceMeetingForgetsTheChoice() async throws {
        var fixture = try await seed()
        try await record(fixture)
        _ = try await read()
        try await store.save(fixture.meeting)
        let untouched = try await builtAt()
        XCTAssertNotNil(untouched)

        fixture.meeting.title = "Weekly sync (old)"
        try await store.save(fixture.meeting)
        let renamed = try await store.meetingBriefLines(for: occurrence())
        var sources = try await count("meetingBriefSource")
        var lineCount = try await count("meetingBriefLine")
        XCTAssertNil(renamed)
        XCTAssertEqual([sources, lineCount], [0, 0])

        try await record(fixture)
        _ = try await read()
        try await store.delete(fixture.meeting.id)
        let deleted = try await store.meetingBriefLines(for: occurrence())
        sources = try await count("meetingBriefSource")
        XCTAssertNil(deleted)
        XCTAssertEqual(sources, 0)
        try await record(fixture)
        sources = try await count("meetingBriefSource")
        XCTAssertEqual(sources, 0, "a tombstoned meeting cannot be recorded")

        try await store.restore(fixture.meeting.id)
        try await record(fixture)
        _ = try await read()
        // Purge only takes tombstoned meetings, which the trigger already forgot.
        let key = fixture.meeting.id.rawValue.uuidString
        try await store.database.write { db in
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [key])
        }
        sources = try await count("meetingBriefSource")
        lineCount = try await count("meetingBriefLine")
        XCTAssertEqual([sources, lineCount], [0, 0])
    }

    func testRecordingReplacesClearsAndPrunes() async throws {
        let fixture = try await seed()
        let other = try await seed(title: "Retro")
        try await record(fixture)
        _ = try await read()

        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: other.meeting.id, at: base)
        let rebuilt = try await builtAt()
        XCTAssertEqual(rebuilt, base)
        let replaced = try await read()
        XCTAssertEqual(replaced.sourceMeetingID, other.meeting.id)
        XCTAssertEqual(replaced.people.map(\.speakerID), [other.marta.id, other.me.id])

        try await store.recordMeetingBriefSource(
            eventID: "event-earlier", eventStartAt: base.addingTimeInterval(-60),
            sourceMeetingID: fixture.meeting.id, at: base)
        var sources = try await count("meetingBriefSource")
        XCTAssertEqual(sources, 1, "the source must start before the event")
        try await store.recordMeetingBriefSource(
            eventID: "event-ongoing", eventStartAt: base.addingTimeInterval(60),
            sourceMeetingID: fixture.meeting.id, at: base)
        sources = try await count("meetingBriefSource")
        XCTAssertEqual(sources, 1, "an ongoing event never continues its own recording")

        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: nil, at: base)
        let clearedLines = try await store.meetingBriefLines(for: occurrence())
        XCTAssertNil(clearedLines)

        try await record(fixture)
        _ = try await read()
        try await store.recordMeetingBriefSource(
            eventID: "event-next", eventStartAt: eventStart.addingTimeInterval(7 * 86_400),
            sourceMeetingID: fixture.meeting.id, at: eventStart.addingTimeInterval(86_400 + 1))
        sources = try await count("meetingBriefSource")
        let prunedLines = try await store.database.read { [eventID] db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM meetingBriefLine
                    JOIN meetingBriefSource AS source ON source.id = meetingBriefLine.sourceID
                    WHERE source.eventID = ?
                    """,
                arguments: [eventID]) ?? 0
        }
        let pruned = try await store.meetingBriefLines(for: occurrence())
        XCTAssertEqual([sources, prunedLines], [1, 0])
        XCTAssertNil(pruned)
    }

    func testEachOccurrenceOfARecurringEventKeepsItsOwnSource() async throws {
        let fixture = try await seed()
        let other = try await seed(title: "Retro")
        let nextWeek = MeetingBriefLines.Occurrence(eventID: eventID, startAt: eventStart.addingTimeInterval(7 * 86_400))
        try await record(fixture)
        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: nextWeek.startAt, sourceMeetingID: other.meeting.id, at: base)

        let both = try await store.meetingBriefLines(for: [occurrence(), nextWeek])

        XCTAssertEqual(both[occurrence()]?.sourceMeetingID, fixture.meeting.id)
        XCTAssertEqual(both[nextWeek]?.sourceMeetingID, other.meeting.id)
    }

    func testAnUnreadableSourceKeepsNoLinesAndIsNotRetriedOnRead() async throws {
        let fixture = try await seed()
        let other = try await seed(title: "Retro")
        try await record(fixture)
        let key = other.meeting.id.rawValue.uuidString
        try await store.database.write { db in
            try db.execute(
                sql: """
                    UPDATE segment SET id = 'not-a-uuid'
                    WHERE rowid = (SELECT MIN(rowid) FROM segment WHERE meetingID = ?)
                    """,
                arguments: [key])
        }

        try await store.recordMeetingBriefSource(
            eventID: eventID, eventStartAt: eventStart, sourceMeetingID: other.meeting.id, at: base)
        let built = try await builtAt()
        let lineCount = try await count("meetingBriefLine")
        _ = try await read()
        let reread = try await builtAt()

        XCTAssertEqual(built, base, "a failed build is settled, not retried on every read")
        XCTAssertEqual(lineCount, 0, "the previous source's lines never outlive the switch")
        XCTAssertEqual(reread, built)
    }

    func testAnEventLinkedRecordingIsItsEventsPreviousOccurrence() async throws {
        let start = eventStart.addingTimeInterval(-7 * 86_400)
        let linked = Meeting(
            title: TitleTemplate.eventTitle("Weekly sync", date: start),
            startedAt: start, endedAt: start.addingTimeInterval(600))
        try await store.save(linked)

        let found = try await store.previousMeetingOccurrence(title: "Weekly sync", before: eventStart)

        XCTAssertEqual(found, linked.id, "a recording linked to the event carries its date in the title")
    }

    func testThePreviewLeadsWithWhatIsStillPending() {
        func line(_ kind: MeetingBriefLines.Kind, _ status: MeetingBriefLines.Status, at time: TimeInterval)
            -> MeetingBriefLines.Line {
            MeetingBriefLines.Line(kind: kind, text: "\(kind) \(time)", segmentID: UUID(), time: time, status: status)
        }
        func lead(_ lines: [MeetingBriefLines.Line]) -> MeetingBriefLines.Line? {
            MeetingBriefLines.Person(
                speakerID: SpeakerID(), personID: nil, isMe: false, label: "S1", displayName: nil, lines: lines
            ).lead
        }
        let quote = line(.quote, .said, at: 10)
        let closed = line(.commitment, .closed, at: 20)
        let unresolved = line(.question, .unresolved, at: 30)
        let open = line(.commitment, .open(due: nil), at: 40)

        XCTAssertEqual(lead([quote, closed, unresolved, open]), unresolved)
        XCTAssertEqual(lead([quote, closed]), closed)
        XCTAssertEqual(lead([quote, line(.quote, .said, at: 50)]), quote)
        XCTAssertNil(lead([]))
    }

    func testPreviousOccurrenceMatchesTheTitleLoosely() async throws {
        func meeting(_ title: String, daysAgo: Double, ended: Bool = true) async throws -> Meeting {
            let start = eventStart.addingTimeInterval(-daysAgo * 86_400)
            let meeting = Meeting(
                title: title, startedAt: start, endedAt: ended ? start.addingTimeInterval(600) : nil)
            try await store.save(meeting)
            return meeting
        }
        _ = try await meeting("Revisión semanal", daysAgo: 21)
        let latest = try await meeting("  REVISION   Semanal ", daysAgo: 7)
        _ = try await meeting("Revisión semanal", daysAgo: 1, ended: false)
        let deleted = try await meeting("Revisión semanal", daysAgo: 2)
        try await store.delete(deleted.id)
        _ = try await meeting("Revisión semanal", daysAgo: -1)
        _ = try await meeting("Revisión mensual", daysAgo: 3)
        _ = try await meeting("Planeación anual", daysAgo: 200)

        _ = try await meeting("Revisión semanal", daysAgo: 0.001)
        let found = try await store.previousMeetingOccurrence(title: "revisión semanal", before: eventStart)
        let none = try await store.previousMeetingOccurrence(title: "Otra cosa", before: eventStart)
        let tooOld = try await store.previousMeetingOccurrence(title: "Planeación anual", before: eventStart)
        let blank = try await store.previousMeetingOccurrence(title: "  ", before: eventStart)

        XCTAssertEqual(found, latest.id)
        XCTAssertNil(none)
        XCTAssertNil(tooOld)
        XCTAssertNil(blank)
    }
}
