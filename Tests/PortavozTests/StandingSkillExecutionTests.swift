import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class StandingSkillExecutionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testV47AddsImmutableAuthorityAndBoundedArtifactTables() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v46")

        try migrator.migrate(database, upTo: "v47")

        try database.read { database in
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                "v47")
            XCTAssertEqual(
                Set(try database.columns(
                    in: "standingSkillExecutionAuthority").map(\.name)),
                [
                    "proposalID", "ruleID", "action",
                    "occurrenceFingerprint", "eventStartAt",
                    "budgetWindowStart", "budgetWindowEnd", "authorizedAt"
                ])
            XCTAssertEqual(
                Set(try database.columns(
                    in: "standingSkillArtifact").map(\.name)),
                [
                    "proposalID", "kind", "formatVersion", "payload",
                    "sha256", "createdAt"
                ])
            let authorityIndexes = try database.indexes(
                on: "standingSkillExecutionAuthority")
            XCTAssertTrue(authorityIndexes.contains(where: {
                $0.isUnique
                    && $0.columns == ["action", "occurrenceFingerprint"]
            }))
        }
    }

    func testV48CanonicalizesPersistedOccurrenceIdentity() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v47")

        let proposalID = UUID()
        let eventID = "calendar-submillisecond"
        let ruleID = StandingSkillRuleID()
        let eventStartAt = now.addingTimeInterval(600.123_456)
        let oldFingerprint = OperationFingerprint.make(
            version: "standing-skill-occurrence-v1",
            components: [
                eventID,
                String(eventStartAt.timeIntervalSinceReferenceDate.bitPattern)
            ])
        let oldKey = "standing-skill:"
            + ruleID.rawValue.uuidString.lowercased()
            + ":\(oldFingerprint)"
        let eventRecordID = UUID()

        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionEvent (
                        id, proposalID, previousEventID, kind, attempt,
                        failureCategory, occurredAt
                    ) VALUES (?, ?, NULL, 'confirm', 1, NULL, ?)
                    """,
                arguments: [
                    eventRecordID.uuidString,
                    proposalID.uuidString,
                    now
                ])
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionState (
                        proposalID, skillID, skillVersion, idempotencyKey,
                        state, attempt, latestEventID, createdAt, updatedAt,
                        failureCategory
                    ) VALUES (?, ?, ?, ?, 'confirmed', 1, ?, ?, ?, NULL)
                    """,
                arguments: [
                    proposalID.uuidString,
                    PreMeetingBriefSkill.id,
                    PreMeetingBriefSkill.version,
                    oldKey,
                    eventRecordID.uuidString,
                    now,
                    now
                ])
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionSubject (
                        proposalID, subjectKind, meetingID, commitmentID,
                        calendarEventID
                    ) VALUES (?, 'calendar-event', NULL, NULL, ?)
                    """,
                arguments: [proposalID.uuidString, eventID])
            try database.execute(
                sql: """
                    INSERT INTO standingSkillExecutionAuthority (
                        proposalID, ruleID, action, occurrenceFingerprint,
                        eventStartAt, budgetWindowStart, budgetWindowEnd,
                        authorizedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    proposalID.uuidString,
                    ruleID.rawValue.uuidString,
                    StandingSkillRuleAction.preparePreMeetingBrief.rawValue,
                    oldFingerprint,
                    eventStartAt,
                    now.addingTimeInterval(-60),
                    now.addingTimeInterval(3_600),
                    now
                ])
        }

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 49)
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT identifier FROM grdb_migrations
                        ORDER BY rowid DESC LIMIT 1
                        """),
                "v49")
            let row = try XCTUnwrap(Row.fetchOne(
                database,
                sql: """
                    SELECT authority.eventStartAt,
                           authority.occurrenceFingerprint,
                           execution.idempotencyKey
                    FROM standingSkillExecutionAuthority AS authority
                    JOIN skillExecutionState AS execution
                      ON execution.proposalID = authority.proposalID
                    WHERE authority.proposalID = ?
                    """,
                arguments: [proposalID.uuidString]))
            let persistedStart: Date = row["eventStartAt"]
            let occurrence = StandingSkillOccurrence(
                eventID: eventID,
                eventStartAt: persistedStart)
            let migratedFingerprint: String = row["occurrenceFingerprint"]
            let migratedKey: String = row["idempotencyKey"]
            XCTAssertNotEqual(migratedFingerprint, oldFingerprint)
            XCTAssertEqual(migratedFingerprint, occurrence.fingerprint)
            XCTAssertEqual(
                migratedKey,
                StandingSkillExecutionIdentity.idempotencyKey(
                    ruleID: ruleID,
                    occurrence: occurrence))
            XCTAssertTrue(occurrence.matches(
                eventID: eventID,
                eventStartAt: eventStartAt))
        }
    }

    func testOccurrenceIdentityUsesDurableMillisecondPrecision() {
        let first = Date(timeIntervalSinceReferenceDate: 700_000_000.123_2)
        let sameStoredMillisecond = Date(
            timeIntervalSinceReferenceDate: 700_000_000.123_4)
        let nextMillisecond = Date(
            timeIntervalSinceReferenceDate: 700_000_000.124_2)
        let occurrence = StandingSkillOccurrence(
            eventID: "calendar-event",
            eventStartAt: first)

        XCTAssertTrue(occurrence.matches(
            eventID: "calendar-event",
            eventStartAt: sameStoredMillisecond))
        XCTAssertEqual(
            occurrence.fingerprint,
            StandingSkillOccurrence.makeFingerprint(
                eventID: "calendar-event",
                eventStartAt: sameStoredMillisecond))
        XCTAssertFalse(occurrence.matches(
            eventID: "calendar-event",
            eventStartAt: nextMillisecond))
        XCTAssertNotEqual(
            occurrence.fingerprint,
            StandingSkillOccurrence.makeFingerprint(
                eventID: "calendar-event",
                eventStartAt: nextMillisecond))
        XCTAssertFalse(StandingSkillOccurrence(
            eventID: "calendar-event",
            eventStartAt: Date(timeIntervalSinceReferenceDate: .infinity)
        ).matches(
            eventID: "calendar-event",
            eventStartAt: Date(timeIntervalSinceReferenceDate: .infinity)))
    }

    func testClaimRechecksPolicyAndConsumesDailyBudgetAtomically() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store, dailyBudget: 2)
        let first = event(id: "event-1", offset: 900)
        let second = event(id: "event-2", offset: 1_200)
        let third = event(id: "event-3", offset: 1_500)

        let firstAdmission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: first))
        guard case .admitted(let firstRecord) = firstAdmission else {
            return XCTFail("expected first claim, got \(firstAdmission)")
        }
        let duplicate = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: first, proposalID: UUID()))
        XCTAssertEqual(duplicate, .duplicate(firstRecord))
        let busy = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: second, proposalID: UUID()))
        XCTAssertEqual(busy, .refused(.ruleBusy))
        _ = try await store.cancelSkillExecution(
            proposalID: firstRecord.proposalID,
            at: now.addingTimeInterval(1))

        let secondAdmission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: second, proposalID: UUID()))
        guard case .admitted(let secondRecord) = secondAdmission else {
            return XCTFail("expected second claim, got \(secondAdmission)")
        }
        _ = try await store.cancelSkillExecution(
            proposalID: secondRecord.proposalID,
            at: now.addingTimeInterval(2))
        let exhausted = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: third, proposalID: UUID()))
        XCTAssertEqual(exhausted, .refused(.dailyBudgetReached))

        try await store.setAllSkillsPaused(true, at: now)
        let paused = try await store.claimStandingSkillExecution(
            claim(
                rule: rule,
                event: event(id: "event-4", offset: 1_800),
                proposalID: UUID()))
        XCTAssertEqual(paused, .refused(.allSkillsPaused))
    }

    func testClaimHonorsManualOwnerDismissalDisablementAndRuleDeletion() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        try await assertManualOwnerRejected(store: store, rule: rule)
        try await assertDismissedEventRejected(store: store, rule: rule)
        try await assertDisabledSkillRejected(store: store, rule: rule)

        let admittedEvent = event(id: "surviving-receipt", offset: 1_800)
        let admitted = try await store.claimStandingSkillExecution(claim(
            rule: rule,
            event: admittedEvent,
            proposalID: UUID()))
        guard case .admitted(let record) = admitted else {
            return XCTFail("expected admission")
        }
        let deleted = try await store.deleteStandingSkillRule(rule.id)
        XCTAssertTrue(deleted)
        let counts = try await store.database.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM standingSkillRule") ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM standingSkillExecutionAuthority") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        let artifact = try StandingPreMeetingBriefArtifactCodec.encode(
            brief(for: admittedEvent),
            at: now.addingTimeInterval(2))
        let deletedRuleCompletion = try await store.completeStandingSkillExecution(
            proposalID: record.proposalID,
            artifact: artifact,
            at: artifact.createdAt)
        XCTAssertEqual(deletedRuleCompletion, .refused(.unknownRule))
    }

    func testCompletionPublishesArtifactAndReceiptInOneTransaction() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let upcoming = event(id: "completed-event", offset: 900)
        let admission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: upcoming))
        guard case .admitted(let record) = admission else {
            return XCTFail("expected admission")
        }
        let completedAt = now.addingTimeInterval(5)
        let expectedBrief = brief(for: upcoming)
        let artifact = try StandingPreMeetingBriefArtifactCodec.encode(
            expectedBrief,
            at: completedAt)

        let completion = try await store.completeStandingSkillExecution(
            proposalID: record.proposalID,
            artifact: artifact,
            at: completedAt)

        guard case .settled(let settled) = completion else {
            return XCTFail("expected settled completion, got \(completion)")
        }
        XCTAssertEqual(settled.state, .succeeded)
        let history = try await store.skillExecutionHistory(
            proposalID: record.proposalID)
        XCTAssertEqual(history.map(\.kind), ["confirm", "begin", "succeed"])
        let pending = try await store.pendingStandingSkillExecutions()
        XCTAssertTrue(pending.isEmpty)
        let persistedArtifact = try await store.standingSkillArtifact(
            proposalID: record.proposalID)
        let persisted = try XCTUnwrap(persistedArtifact)
        XCTAssertEqual(persisted, artifact)
        XCTAssertEqual(
            try StandingPreMeetingBriefArtifactCodec.decode(persisted),
            expectedBrief)
        let repeatedCompletion = try await store.completeStandingSkillExecution(
            proposalID: record.proposalID,
            artifact: artifact,
            at: completedAt)
        XCTAssertEqual(repeatedCompletion, .alreadySettled(settled))
    }

    func testFailureRetriesAreBoundedAndExecutingStateNeverRepeats() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let upcoming = event(id: "retry-event", offset: 900)
        let admission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: upcoming))
        guard case .admitted(let record) = admission else {
            return XCTFail("expected admission")
        }

        for expectedAttempt in 1...3 {
            let outcome = try await store.failStandingSkillExecution(
                proposalID: record.proposalID,
                category: .recoverable,
                at: now.addingTimeInterval(Double(expectedAttempt)))
            guard case .settled(let failed) = outcome else {
                return XCTFail("expected failed attempt \(expectedAttempt)")
            }
            XCTAssertEqual(failed.state, .failed)
            XCTAssertEqual(failed.attempt, expectedAttempt)
        }
        let exhausted = try await store.failStandingSkillExecution(
            proposalID: record.proposalID,
            category: .recoverable,
            at: now.addingTimeInterval(4))
        XCTAssertEqual(exhausted, .refused(.retryLimitReached))
        let pending = try await store.pendingStandingSkillExecutions()
        XCTAssertEqual(pending.first?.record.attempt, 3)

        let otherEvent = event(id: "executing-event", offset: 1_200)
        let otherAdmission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: otherEvent, proposalID: UUID()))
        guard case .admitted(let other) = otherAdmission else {
            return XCTFail("failed terminal work must not hold the single-flight fence")
        }
        _ = try await store.beginSkillExecution(
            proposalID: other.proposalID,
            at: now)
        let otherArtifact = try StandingPreMeetingBriefArtifactCodec.encode(
            brief(for: otherEvent),
            at: now.addingTimeInterval(5))
        let executingCompletion = try await store.completeStandingSkillExecution(
            proposalID: other.proposalID,
            artifact: otherArtifact,
            at: otherArtifact.createdAt)
        XCTAssertEqual(executingCompletion, .refused(.illegalTransition))
        let pendingAfterBegin = try await store.pendingStandingSkillExecutions()
        XCTAssertEqual(
            pendingAfterBegin.first(where: {
                $0.record.proposalID == other.proposalID
            })?.record.state,
            .executing)
    }

    func testConcurrentClaimsHaveOneExactOccurrenceOwner() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store, dailyBudget: 8)
        let upcoming = event(id: "race-event", offset: 900)
        let claims = (0..<16).map { _ in
            claim(rule: rule, event: upcoming, proposalID: UUID())
        }

        let outcomes = try await withThrowingTaskGroup(
            of: StandingSkillExecutionAdmission.self
        ) { group in
            for claim in claims {
                group.addTask {
                    try await store.claimStandingSkillExecution(claim)
                }
            }
            var values: [StandingSkillExecutionAdmission] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outcomes.filter {
            if case .admitted = $0 { true } else { false }
        }.count, 1)
        XCTAssertEqual(outcomes.filter {
            if case .duplicate = $0 { true } else { false }
        }.count, 15)
        let counts = try await store.database.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionState") ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM standingSkillExecutionAuthority") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testCorruptOccurrenceAndArtifactFailClosed() async throws {
        try await assertCorruptArtifactRejected()
        try await assertCorruptOccurrenceRejected()
        try await assertCorruptAttemptRejected()
    }

}

private extension StandingSkillExecutionTests {

    func assertManualOwnerRejected(
        store: MeetingStore,
        rule: StandingSkillRule
    ) async throws {
        let owned = event(id: "manual-event", offset: 900)
        let key = PreMeetingBriefSkill.idempotencyKey(forEvent: owned.id)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: UUID(),
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version,
            subject: .calendarEvent(owned.id),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        let outcome = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: owned))
        XCTAssertEqual(outcome, .refused(.eventAlreadyOwned))
    }

    func assertDismissedEventRejected(
        store: MeetingStore,
        rule: StandingSkillRule
    ) async throws {
        let dismissed = event(id: "dismissed-event", offset: 1_200)
        try await store.dismissSkillOffer(
            offerKey: PreMeetingBriefSkill.idempotencyKey(
                forEvent: dismissed.id),
            skillID: PreMeetingBriefSkill.id,
            at: now)
        let outcome = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: dismissed, proposalID: UUID()))
        XCTAssertEqual(outcome, .refused(.eventDismissed))
    }

    func assertDisabledSkillRejected(
        store: MeetingStore,
        rule: StandingSkillRule
    ) async throws {
        try await store.setSkill(
            PreMeetingBriefSkill.id,
            isEnabled: false,
            at: now)
        let outcome = try await store.claimStandingSkillExecution(claim(
            rule: rule,
            event: event(id: "disabled-event", offset: 1_500),
            proposalID: UUID()))
        XCTAssertEqual(outcome, .refused(.skillDisabled))
        try await store.setSkill(
            PreMeetingBriefSkill.id,
            isEnabled: true,
            at: now)
    }

    func assertCorruptArtifactRejected() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let upcoming = event(id: "corrupt-event", offset: 900)
        let admission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: upcoming))
        guard case .admitted(let record) = admission else {
            return XCTFail("expected admission")
        }
        let artifact = try StandingPreMeetingBriefArtifactCodec.encode(
            brief(for: upcoming),
            at: now.addingTimeInterval(2))
        _ = try await store.completeStandingSkillExecution(
            proposalID: record.proposalID,
            artifact: artifact,
            at: artifact.createdAt)
        try await store.database.write { database in
            try database.execute(
                sql: "DROP TRIGGER standingSkillArtifact_no_update")
            try database.execute(
                sql: "UPDATE standingSkillArtifact SET sha256 = ?",
                arguments: [String(repeating: "0", count: 64)])
        }
        await assertStorageError(
            "invalid standing Skill execution: artifact digest or bounds mismatch"
        ) {
            _ = try await store.standingSkillArtifact(
                proposalID: record.proposalID)
        }
    }

    func assertCorruptOccurrenceRejected() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let upcoming = event(id: "corrupt-pending", offset: 1_200)
        _ = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: upcoming))
        try await store.database.write { database in
            try database.execute(
                sql: "DROP TRIGGER standingSkillExecutionAuthority_no_update")
            try database.execute(
                sql: """
                    UPDATE standingSkillExecutionAuthority
                    SET occurrenceFingerprint = ?
                    """,
                arguments: [String(repeating: "f", count: 64)])
        }
        await assertStorageError(
            "invalid standing Skill execution: pending occurrence fingerprint mismatch"
        ) {
            _ = try await store.pendingStandingSkillExecutions()
        }
    }

    func assertCorruptAttemptRejected() async throws {
        let store = try MeetingStore.inMemory()
        let rule = try await createRule(in: store)
        let upcoming = event(id: "corrupt-attempt", offset: 1_500)
        let admission = try await store.claimStandingSkillExecution(
            claim(rule: rule, event: upcoming))
        guard case .admitted(let record) = admission else {
            return XCTFail("expected attempt owner")
        }
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET attempt = 2 WHERE proposalID = ?
                    """,
                arguments: [record.proposalID.uuidString])
        }
        await assertStorageError(
            "invalid standing Skill execution: pending owner has invalid state or attempt"
        ) {
            _ = try await store.pendingStandingSkillExecutions()
        }
    }

    func assertStorageError(
        _ expected: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected corrupt standing execution to fail closed")
        } catch let error as StorageError {
            XCTAssertEqual(error.errorDescription, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func createRule(
        in store: MeetingStore,
        dailyBudget: Int = 3
    ) async throws -> StandingSkillRule {
        let instant = now
        let outcome = try await CreateStandingSkillRule(
            store: store,
            now: { instant }
        ).execute(CreateStandingSkillRuleRequest(
            template: .prepareEveryUpcomingBrief,
            maximumDailyExecutions: dailyBudget))
        return switch outcome {
        case .created(let rule), .alreadyExists(let rule): rule
        }
    }

    private func claim(
        rule: StandingSkillRule,
        event: UpcomingEvent,
        proposalID: UUID = UUID()
    ) -> StandingSkillExecutionClaim {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.startOfDay(for: now)
        let occurrence = StandingSkillOccurrence(
            eventID: event.id,
            eventStartAt: event.startDate)
        return StandingSkillExecutionClaim(
            proposalID: proposalID,
            ruleID: rule.id,
            skillID: rule.skillID,
            skillVersion: rule.skillVersion,
            trigger: rule.trigger,
            subjectPredicate: rule.subjectPredicate,
            action: rule.action,
            occurrence: occurrence,
            dailyWindow: StandingSkillDailyWindow(
                startInclusive: dayStart,
                endExclusive: calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: dayStart)!),
            oneShotOfferKey: PreMeetingBriefSkill.idempotencyKey(
                forEvent: event.id),
            idempotencyKey: StandingSkillExecutionIdentity.idempotencyKey(
                ruleID: rule.id,
                occurrence: occurrence),
            occurredAt: now)
    }

    private func event(id: String, offset: TimeInterval) -> UpcomingEvent {
        UpcomingEvent(
            id: id,
            title: "Private planning title",
            startDate: now.addingTimeInterval(offset),
            attendees: ["Ana"])
    }

    private func brief(for event: UpcomingEvent) -> MeetingBrief {
        let meetingID = MeetingID()
        return MeetingBrief(
            event: event,
            related: [MeetingBrief.RelatedMeeting(
                meetingID: meetingID,
                title: "Earlier rollout",
                overview: "Budget approved",
                matchedTerms: ["rollout"],
                snippet: "Approved in the earlier meeting")],
            openItems: [MeetingBrief.OpenItem(
                id: UUID(),
                meetingID: meetingID,
                meetingTitle: "Earlier rollout",
                text: "Send the plan")],
            whatToKnow: [MeetingBrief.KnowPoint(
                id: UUID(),
                text: "The budget was approved.",
                meetingID: meetingID,
                meetingTitle: "Earlier rollout")])
    }
}
