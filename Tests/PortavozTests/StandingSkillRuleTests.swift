import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class StandingSkillRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testV46AddsContentFreeClosedStandingRuleAuthority() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v45")

        try migrator.migrate(database, upTo: "v46")

        try database.read { database in
            XCTAssertGreaterThanOrEqual(StorageSchema.version, 46)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ).last,
                "v46")
            let columns = try Set(
                database.columns(in: "standingSkillRule").map(\.name))
            XCTAssertEqual(columns, [
                "id", "skillID", "skillVersion", "trigger",
                "subjectPredicate", "action", "maximumDailyExecutions",
                "isEnabled", "createdAt", "updatedAt"
            ])
            for forbidden in [
                "title", "attendees", "transcript", "meetingID",
                "destination", "provider", "credentials"
            ] {
                XCTAssertFalse(columns.contains(forbidden))
            }
            let uniqueIndexes = try database.indexes(
                on: "standingSkillRule").filter(\.isUnique)
            XCTAssertTrue(uniqueIndexes.contains(where: {
                $0.columns == ["trigger", "subjectPredicate", "action"]
            }))
        }
    }

    func testInitialTemplateAdmitsOnlyReversibleLocalBriefPreparation() {
        XCTAssertEqual(StandingSkillRuleTemplate.allCases, [
            .prepareEveryUpcomingBrief
        ])
        let definition = StandingSkillRuleTemplate
            .prepareEveryUpcomingBrief.definition
        XCTAssertEqual(definition, PreMeetingBriefSkill.definition)
        XCTAssertTrue(definition.isValid)
        XCTAssertTrue(definition.isReversible)
        XCTAssertFalse(definition.declaresExternalEffect)
        XCTAssertFalse(definition.capabilities.contains(.writeLocalFile))

        let rule = StandingSkillRuleTemplate.prepareEveryUpcomingBrief
            .makeRule(at: now)
        XCTAssertTrue(rule.isValid)
        XCTAssertEqual(rule.maximumDailyExecutions, 3)
        XCTAssertEqual(rule.trigger, .upcomingCalendarEvent)
        XCTAssertEqual(rule.subjectPredicate, .anyUpcomingCalendarEvent)
        XCTAssertEqual(rule.action, .preparePreMeetingBrief)
    }

    func testCreateIsIdempotentAndWritesNoExecutionReceipt() async throws {
        let store = try MeetingStore.inMemory()
        let identifier = StandingSkillRuleID()
        let instant = now
        let create = CreateStandingSkillRule(
            store: store,
            makeID: { identifier },
            now: { instant })
        let request = CreateStandingSkillRuleRequest(
            template: .prepareEveryUpcomingBrief,
            maximumDailyExecutions: 4)

        let first = try await create.execute(request)
        let second = try await create.execute(request)
        let rules = try await store.standingSkillRules()
        let receiptCounts = try await store.database.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionState") ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionEvent") ?? -1
            )
        }

        XCTAssertEqual(first, .created(try XCTUnwrap(rules.first)))
        XCTAssertEqual(second, .alreadyExists(try XCTUnwrap(rules.first)))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(receiptCounts.0, 0)
        XCTAssertEqual(receiptCounts.1, 0)
    }

    func testControlSnapshotCombinesRulePauseAndSkillDisablement() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        _ = try await CreateStandingSkillRule(
            store: store,
            now: { instant }).execute(CreateStandingSkillRuleRequest(
                template: .prepareEveryUpcomingBrief))
        let load = LoadStandingSkillRules(store: store)

        var snapshot = try await load.execute(())
        XCTAssertFalse(snapshot.isPaused)
        XCTAssertEqual(snapshot.rules.count, 1)
        XCTAssertEqual(snapshot.rules.first?.compatibility, .current)
        XCTAssertEqual(snapshot.rules.first?.isEffectivelyEnabled, true)

        try await store.setAllSkillsPaused(true, at: now)
        snapshot = try await load.execute(())
        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.rules.first?.isEffectivelyEnabled, false)

        try await store.setAllSkillsPaused(false, at: now)
        try await store.setSkill(
            PreMeetingBriefSkill.id,
            isEnabled: false,
            at: now)
        snapshot = try await load.execute(())
        XCTAssertFalse(snapshot.isPaused)
        XCTAssertEqual(snapshot.rules.first?.isEffectivelyEnabled, false)
        XCTAssertEqual(snapshot.rules.first?.rule.isEnabled, true)
    }

    func testDisableAndDeletePersistAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("portavoz.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store: MeetingStore? = try MeetingStore(databaseURL: databaseURL)
        let identifier = StandingSkillRuleID()
        let instant = now
        _ = try await CreateStandingSkillRule(
            store: try XCTUnwrap(store),
            makeID: { identifier },
            now: { instant }).execute(CreateStandingSkillRuleRequest(
                template: .prepareEveryUpcomingBrief))
        let disableOutcome = try await ManageStandingSkillRule(
            store: try XCTUnwrap(store),
            now: { instant.addingTimeInterval(1) }
        ).execute(.setEnabled(id: identifier, isEnabled: false))
        XCTAssertEqual(disableOutcome, .updated)

        store = nil
        store = try MeetingStore(databaseURL: databaseURL)
        var rules = try await XCTUnwrap(store).standingSkillRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertFalse(try XCTUnwrap(rules.first).isEnabled)
        let deleteOutcome = try await ManageStandingSkillRule(
            store: try XCTUnwrap(store)
        ).execute(.delete(id: identifier))
        XCTAssertEqual(deleteOutcome, .deleted)

        store = nil
        store = try MeetingStore(databaseURL: databaseURL)
        rules = try await XCTUnwrap(store).standingSkillRules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testStaleDefinitionFailsClosedButCanBeDisabledOrDeleted() async throws {
        let store = try MeetingStore.inMemory()
        let identifier = StandingSkillRuleID()
        let rule = StandingSkillRule(
            id: identifier,
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version + 1,
            trigger: .upcomingCalendarEvent,
            subjectPredicate: .anyUpcomingCalendarEvent,
            action: .preparePreMeetingBrief,
            maximumDailyExecutions: 3,
            isEnabled: true,
            createdAt: now,
            updatedAt: now)
        let inserted = try await store.insertStandingSkillRule(rule)
        XCTAssertEqual(inserted, .inserted)

        var snapshot = try await LoadStandingSkillRules(
            store: store).execute(())
        XCTAssertEqual(snapshot.rules.first?.compatibility, .staleDefinition)
        XCTAssertEqual(snapshot.rules.first?.isEffectivelyEnabled, false)
        let instant = now
        let manage = ManageStandingSkillRule(store: store, now: { instant })
        let enableOutcome = try await manage.execute(.setEnabled(
            id: identifier,
            isEnabled: true))
        XCTAssertEqual(enableOutcome, .staleDefinition)
        let disableOutcome = try await manage.execute(.setEnabled(
            id: identifier,
            isEnabled: false))
        XCTAssertEqual(disableOutcome, .updated)
        snapshot = try await LoadStandingSkillRules(store: store).execute(())
        XCTAssertFalse(try XCTUnwrap(snapshot.rules.first).rule.isEnabled)
        let deleteOutcome = try await manage.execute(.delete(id: identifier))
        XCTAssertEqual(deleteOutcome, .deleted)
    }

    func testMalformedPersistedAuthorityFailsClosed() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        _ = try await CreateStandingSkillRule(
            store: store,
            now: { instant }).execute(CreateStandingSkillRuleRequest(
                template: .prepareEveryUpcomingBrief))
        try await store.database.write { database in
            try database.execute(
                sql: "UPDATE standingSkillRule SET id = ?",
                arguments: [String(repeating: "x", count: 36)])
        }

        do {
            _ = try await store.standingSkillRules()
            XCTFail("malformed durable authority must never be loaded")
        } catch let error as StorageError {
            guard case .invalidPersistedUUID(
                table: "standingSkillRule",
                column: "id",
                value: String(repeating: "x", count: 36)
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try await store.database.write { database in
            try database.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try database.execute(
                sql: "UPDATE standingSkillRule SET id = ?, action = ?",
                arguments: [UUID().uuidString, "unknown-action"])
        }
        do {
            _ = try await store.standingSkillRules()
            XCTFail("unknown durable authority must never be loaded")
        } catch let error as StorageError {
            guard case .invalidStandingSkillRule(
                "unknown trigger, predicate, or action"
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBoundsAndInvalidTimestampsFailClosed() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        let invalidRule = StandingSkillRuleTemplate.prepareEveryUpcomingBrief
            .makeRule(maximumDailyExecutions: 0, at: instant)
        XCTAssertFalse(invalidRule.isValid)
        XCTAssertFalse(
            StandingSkillRuleTemplate.prepareEveryUpcomingBrief.matches(
                invalidRule))
        let zeroLimit = try await store.standingSkillRules(limit: 0)
        let oversizedLimit = try await store.standingSkillRules(limit: 33)
        XCTAssertTrue(zeroLimit.isEmpty)
        XCTAssertTrue(oversizedLimit.isEmpty)

        do {
            _ = try await store.insertStandingSkillRule(invalidRule)
            XCTFail("invalid daily authority must not be persisted")
        } catch let error as StorageError {
            XCTAssertEqual(
                error.errorDescription,
                "invalid standing Skill rule: invalid input")
        }
        do {
            _ = try await CreateStandingSkillRule(
                store: store,
                now: {
                    Date(timeIntervalSinceReferenceDate: .infinity)
                }).execute(CreateStandingSkillRuleRequest(
                    template: .prepareEveryUpcomingBrief))
            XCTFail("non-finite authority timestamps must fail closed")
        } catch let error as CreateStandingSkillRuleError {
            XCTAssertEqual(error, .invalidTimestamp)
        }

        try await store.database.write { database in
            try database.execute(sql: "PRAGMA ignore_check_constraints = ON")
            for index in 0..<StandingSkillRule.maximumRuleCount {
                try database.execute(
                    sql: """
                        INSERT INTO standingSkillRule (
                            id, skillID, skillVersion, trigger,
                            subjectPredicate, action,
                            maximumDailyExecutions, isEnabled,
                            createdAt, updatedAt
                        ) VALUES (?, ?, 1, ?, ?, ?, 1, 1, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        "capacity-seed-\(index)",
                        "trigger-\(index)",
                        "predicate-\(index)",
                        "action-\(index)",
                        instant,
                        instant
                    ])
            }
        }
        do {
            _ = try await CreateStandingSkillRule(
                store: store,
                now: { instant }).execute(CreateStandingSkillRuleRequest(
                    template: .prepareEveryUpcomingBrief))
            XCTFail("the application ceiling must be a typed refusal")
        } catch let error as CreateStandingSkillRuleError {
            XCTAssertEqual(error, .capacityReached)
        }
    }
}
