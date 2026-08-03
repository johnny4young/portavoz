import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentRadarQueryTests: XCTestCase {
    func testQueryRejectsUnboundedLimitsAndInvalidWindows() throws {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertThrowsError(try CommitmentRadarQuery(
            dayStart: dayStart,
            dueSoonEnd: dayStart,
            newSince: dayStart)) { error in
                XCTAssertEqual(error as? CommitmentRadarQueryError, .invalidDateWindow)
            }
        XCTAssertThrowsError(try CommitmentRadarQuery(
            dayStart: dayStart,
            dueSoonEnd: dayStart.addingTimeInterval(86_400),
            newSince: dayStart,
            itemLimit: CommitmentRadarQuery.maximumItemCount + 1)) { error in
                XCTAssertEqual(error as? CommitmentRadarQueryError, .invalidLimit)
            }
        XCTAssertThrowsError(try CommitmentRadarQuery(
            dayStart: dayStart,
            dueSoonEnd: dayStart.addingTimeInterval(86_400),
            newSince: dayStart,
            sourceLimitPerItem: 0)) { error in
                XCTAssertEqual(error as? CommitmentRadarQueryError, .invalidLimit)
            }
    }

    func testUseCaseOwnsSevenDayCalendarBoundaries() async throws {
        let calendar = Self.utcCalendar
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 2,
            hour: 15)))
        let repository = CommitmentRadarRepositoryFake()
        let useCase = LoadCommitmentRadar(
            repository: repository,
            calendar: calendar,
            now: { now })

        _ = try await useCase.execute(LoadCommitmentRadarRequest(
            owner: .mine,
            due: .overdue,
            activity: .activity(.unchanged),
            itemLimit: 41,
            sourceLimitPerItem: 2,
            historyLimitPerItem: 5))

        let queries = await repository.queries
        let query = try XCTUnwrap(queries.first)
        let dayStart = calendar.startOfDay(for: now)
        XCTAssertEqual(query.owner, .mine)
        XCTAssertEqual(query.due, .overdue)
        XCTAssertEqual(query.activity, .activity(.unchanged))
        XCTAssertEqual(query.dayStart, dayStart)
        XCTAssertEqual(
            query.dueSoonEnd,
            calendar.date(byAdding: .day, value: 7, to: dayStart))
        XCTAssertEqual(
            query.newSince,
            calendar.date(byAdding: .day, value: -7, to: dayStart))
        XCTAssertEqual(query.itemLimit, 41)
        XCTAssertEqual(query.sourceLimitPerItem, 2)
        XCTAssertEqual(query.historyLimitPerItem, 5)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }
}

final class CommitmentRadarStorageTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_801_440_000)

    func testOwnerDueAndActivityFiltersRemainIndependentAndExact() async throws {
        let store = try MeetingStore.inMemory()
        let oldDate = dayStart.addingTimeInterval(-10 * 86_400)
        let person = Person(preferredName: "Alex Rivera")
        try await insert(person, into: store, at: oldDate)

        let mine = try await confirm(
            "Mine overdue",
            assignee: .me,
            dueAt: dayStart.addingTimeInterval(-3_600),
            at: oldDate,
            store: store)
        let theirs = try await confirm(
            "Their due soon",
            assignee: .person(person.id),
            dueAt: dayStart.addingTimeInterval(2 * 86_400),
            at: oldDate.addingTimeInterval(1),
            store: store)
        let fresh = try await confirm(
            "Fresh and unassigned",
            at: dayStart.addingTimeInterval(3_600),
            store: store)
        let completed = try await confirm(
            "Already complete",
            at: oldDate.addingTimeInterval(2),
            store: store)
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: completed.id,
            at: oldDate.addingTimeInterval(3))
        let reopened = try await confirm(
            "Reopened work",
            at: oldDate.addingTimeInterval(4),
            store: store)
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: reopened.id,
            at: oldDate.addingTimeInterval(5))
        _ = try await store.applyCommitmentTransition(
            .reopen,
            to: reopened.id,
            at: dayStart.addingTimeInterval(-2 * 86_400))
        let unchanged = try await confirm(
            "Still open",
            at: oldDate.addingTimeInterval(6),
            store: store)

        let mineItems = try await page(store, owner: .mine).items
        let otherItems = try await page(store, owner: .others).items
        let unassignedItems = try await page(store, owner: .unassigned).items
        XCTAssertEqual(mineItems.map(\.id), [mine.id])
        XCTAssertEqual(otherItems.map(\.id), [theirs.id])
        XCTAssertEqual(
            Set(unassignedItems.map(\.id)),
            Set([fresh.id, completed.id, reopened.id, unchanged.id]))

        let overdueItems = try await page(store, due: .overdue).items
        let dueSoonItems = try await page(store, due: .dueSoon).items
        let noDateItems = try await page(store, due: .noDate).items
        XCTAssertEqual(overdueItems.map(\.id), [mine.id])
        XCTAssertEqual(dueSoonItems.map(\.id), [theirs.id])
        XCTAssertEqual(
            Set(noDateItems.map(\.id)),
            Set([fresh.id, reopened.id, unchanged.id]))

        let newItems = try await page(store, activity: .activity(.new)).items
        let completedItems = try await page(
            store,
            activity: .activity(.completed)).items
        let reopenedItems = try await page(
            store,
            activity: .activity(.reopened)).items
        let unchangedItems = try await page(
            store,
            activity: .activity(.unchanged)).items
        XCTAssertEqual(newItems.map(\.id), [fresh.id])
        XCTAssertEqual(completedItems.map(\.id), [completed.id])
        XCTAssertEqual(reopenedItems.map(\.id), [reopened.id])
        XCTAssertEqual(
            Set(unchangedItems.map(\.id)),
            Set([mine.id, theirs.id, unchanged.id]))
    }

    func testRadarBoundsSourcesAndNewestHistoryWithoutHidingCounts() async throws {
        let store = try MeetingStore.inMemory()
        let commitmentID = CommitmentID()
        let sources = (0..<5).map { offset in
            CommitmentSource(
                commitmentID: commitmentID,
                kind: .manual,
                meetingID: nil,
                firstSeenAt: dayStart.addingTimeInterval(Double(offset)))
        }
        var events = [CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            assignee: .unassigned,
            occurredAt: dayStart)]
        for offset in 1..<10 {
            events.append(CommitmentEvent(
                commitmentID: commitmentID,
                kind: .reassign,
                assignee: offset.isMultiple(of: 2) ? .me : .unassigned,
                occurredAt: dayStart.addingTimeInterval(Double(offset))))
        }
        let commitment = try CommitmentContinuityPolicy.projectedCommitment(
            id: commitmentID,
            title: "Bound every related row",
            events: events)
        _ = try await store.applyCommitmentContinuityEnvelope(
            CommitmentContinuityEnvelope(
                commitment: commitment,
                sources: sources,
                events: events))

        let result = try await page(
            store,
            itemLimit: 1,
            sourceLimit: 2,
            historyLimit: 3)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.sourceCount, 5)
        XCTAssertEqual(item.sources.map(\.id), Array(sources.prefix(2)).map(\.id))
        XCTAssertTrue(item.hasMoreSources)
        XCTAssertEqual(item.historyCount, 10)
        XCTAssertEqual(item.history.map(\.id), Array(events.suffix(3).reversed()).map(\.id))
        XCTAssertTrue(item.hasMoreHistory)
        XCTAssertEqual(result.totalCount, 1)
        XCTAssertFalse(result.hasMore)
    }

    func testRadarPreservesExactPersonAndMeetingSourceNavigation() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Planning review",
            startedAt: dayStart.addingTimeInterval(-3_600))
        try await store.save(meeting)
        let person = Person(preferredName: "Sam Lee")
        try await insert(person, into: store, at: dayStart)

        let envelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Publish the rollout notes",
                assignee: .person(person.id),
                origin: .manual(meetingID: meeting.id)),
            at: dayStart.addingTimeInterval(60))
        let result = try await page(store, owner: .person(person.id))

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.id, envelope.commitment.id)
        XCTAssertEqual(item.assigneeDisplayName, "Sam Lee")
        XCTAssertEqual(item.sources.first?.meetingID, meeting.id)
        XCTAssertEqual(item.sources.first?.meetingTitle, "Planning review")
        XCTAssertEqual(item.sources.first?.isMeetingAvailable, true)
        XCTAssertEqual(item.history.first?.assigneeDisplayName, "Sam Lee")
        XCTAssertEqual(item.history.first?.sourceMeetingID, meeting.id)
        XCTAssertEqual(item.history.first?.sourceMeetingTitle, "Planning review")
        XCTAssertEqual(item.history.first?.isSourceMeetingAvailable, true)
    }

    func testRadarUsesFourSelectsIndependentOfRootCount() async throws {
        let store = try MeetingStore.inMemory()
        let person = Person(preferredName: "Query Counter")
        try await insert(person, into: store, at: dayStart)
        for offset in 0..<25 {
            _ = try await confirm(
                "Commitment \(offset)",
                assignee: .person(person.id),
                at: dayStart.addingTimeInterval(Double(offset)),
                store: store)
        }
        let counter = SQLStatementCounter()
        try await store.database.write { database in
            database.trace(options: .statement) { counter.record($0) }
        }

        _ = try await page(store, itemLimit: 25)

        try await store.database.write { database in
            database.trace(options: [])
        }
        XCTAssertEqual(counter.readStatementCount, 4)
    }

    func testRadarRejectsProjectionThatDisagreesWithLatestEvent() async throws {
        let store = try MeetingStore.inMemory()
        let commitment = try await confirm(
            "Keep lifecycle truth coherent",
            at: dayStart,
            store: store)
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE commitment SET status = 'done' WHERE id = ?",
                arguments: [commitment.id.rawValue.uuidString])
        }

        do {
            _ = try await page(store)
            XCTFail("Expected Radar to reject a corrupted lifecycle projection")
        } catch let error as StorageError {
            guard case .invalidCommitment(let reason) = error else {
                return XCTFail("Unexpected storage error: \(error)")
            }
            XCTAssertEqual(
                reason,
                "Radar root does not match its latest lifecycle event")
        }
    }

    private func page(
        _ store: MeetingStore,
        owner: CommitmentRadarOwnerFilter = .all,
        due: CommitmentRadarDueFilter = .all,
        activity: CommitmentRadarActivityFilter = .all,
        itemLimit: Int = 100,
        sourceLimit: Int = 3,
        historyLimit: Int = 8
    ) async throws -> CommitmentRadarPage {
        try await store.commitmentRadar(CommitmentRadarQuery(
            owner: owner,
            due: due,
            activity: activity,
            dayStart: dayStart,
            dueSoonEnd: dayStart.addingTimeInterval(7 * 86_400),
            newSince: dayStart.addingTimeInterval(-7 * 86_400),
            itemLimit: itemLimit,
            sourceLimitPerItem: sourceLimit,
            historyLimitPerItem: historyLimit))
    }

    private func confirm(
        _ title: String,
        assignee: CommitmentAssignee = .unassigned,
        dueAt: Date? = nil,
        at date: Date,
        store: MeetingStore
    ) async throws -> Commitment {
        try await store.confirmCommitment(
            CommitmentConfirmation(
                title: title,
                assignee: assignee,
                dueAt: dueAt,
                origin: .manual(meetingID: nil)),
            at: date).commitment
    }

    private func insert(
        _ person: Person,
        into store: MeetingStore,
        at date: Date
    ) async throws {
        try await store.database.write { database in
            try PersonRecord(person, createdAt: date, updatedAt: date).insert(database)
        }
    }
}

final class ManageCommitmentRadarTests: XCTestCase {
    func testUseCaseMapsOnlyExplicitRadarMutationsToDurableTransitions() async throws {
        let now = Date(timeIntervalSince1970: 1_810_000_000)
        let dueAt = now.addingTimeInterval(86_400)
        let commitmentID = CommitmentID()
        let eventIDs = [CommitmentEventID(), CommitmentEventID(), CommitmentEventID()]
        let repository = CommitmentRadarMutationRepositoryFake()
        let mutations: [CommitmentRadarMutation] = [
            .complete,
            .reopen,
            .reschedule(dueAt),
        ]
        for (eventID, mutation) in zip(eventIDs, mutations) {
            _ = try await ManageCommitmentRadar(
                repository: repository,
                now: { now },
                makeEventID: { eventID })
                .execute(ManageCommitmentRadarRequest(
                    commitmentID: commitmentID,
                    mutation: mutation))
        }

        let calls = await repository.calls
        XCTAssertEqual(calls.map(\.transition), [
            .complete,
            .reopen,
            .reschedule(dueAt),
        ])
        XCTAssertEqual(calls.map(\.commitmentID), Array(repeating: commitmentID, count: 3))
        XCTAssertEqual(calls.map(\.eventID), eventIDs)
        XCTAssertTrue(calls.allSatisfy { $0.sourceMeetingID == nil })
        XCTAssertEqual(calls.map(\.date), Array(repeating: now, count: 3))
    }
}

private actor CommitmentRadarRepositoryFake: CommitmentRadarReading {
    private(set) var queries: [CommitmentRadarQuery] = []

    func commitmentRadar(
        _ query: CommitmentRadarQuery
    ) -> CommitmentRadarPage {
        queries.append(query)
        return CommitmentRadarPage(items: [], totalCount: 0)
    }
}

private actor CommitmentRadarMutationRepositoryFake: CommitmentRadarMutating {
    struct Call: Sendable {
        let transition: CommitmentTransition
        let commitmentID: CommitmentID
        let eventID: CommitmentEventID
        let sourceMeetingID: MeetingID?
        let date: Date
    }

    private(set) var calls: [Call] = []

    func applyCommitmentTransition(
        _ transition: CommitmentTransition,
        to commitmentID: CommitmentID,
        eventID: CommitmentEventID,
        sourceMeetingID: MeetingID?,
        evidence: CommitmentEventEvidence?,
        at proposedDate: Date
    ) async throws -> CommitmentContinuityEnvelope {
        XCTAssertNil(evidence)
        calls.append(Call(
            transition: transition,
            commitmentID: commitmentID,
            eventID: eventID,
            sourceMeetingID: sourceMeetingID,
            date: proposedDate))
        let source = CommitmentSource(
            commitmentID: commitmentID,
            kind: .manual,
            meetingID: nil,
            firstSeenAt: proposedDate)
        let confirm = CommitmentEvent(
            commitmentID: commitmentID,
            kind: .confirm,
            occurredAt: proposedDate)
        return try CommitmentContinuityEnvelope(
            commitment: CommitmentContinuityPolicy.projectedCommitment(
                id: commitmentID,
                title: "Test commitment",
                events: [confirm]),
            sources: [source],
            events: [confirm])
    }
}

private final class SQLStatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var statements = 0

    var readStatementCount: Int {
        lock.withLock { statements }
    }

    func record(_ event: Database.TraceEvent) {
        guard case .statement(let statement) = event else { return }
        let sql = statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard sql.hasPrefix("SELECT") || sql.hasPrefix("WITH") else { return }
        lock.withLock { statements += 1 }
    }
}
