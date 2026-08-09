import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SkillsControlCenterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testV35AddsContentFreeControlStateAndRecentReceiptIndex() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v34")

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 35)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v35")
            XCTAssertEqual(
                try Set(database.columns(in: "skillControl").map(\.name)),
                ["id", "isPaused", "updatedAt"])
            XCTAssertEqual(
                try Set(database.columns(in: "skillDisablement").map(\.name)),
                ["skillID", "disabledAt"])
            XCTAssertEqual(
                try Bool.fetchOne(
                    database,
                    sql: "SELECT isPaused FROM skillControl WHERE id = 1"),
                false)
            let indexColumns = try Row.fetchAll(
                database,
                sql: "PRAGMA index_xinfo(skillExecutionState_on_recent)")
                .filter { ($0["key"] as Int) == 1 }
            XCTAssertEqual(
                indexColumns.map { $0["name"] as String },
                ["updatedAt", "proposalID"])
            XCTAssertEqual(
                indexColumns.map { $0["desc"] as Int },
                [1, 0])
        }
    }

    func testDefaultPolicyPersistsPauseAndIndividualChoicesIndependently() async throws {
        let store = try MeetingStore.inMemory()

        let defaultPolicy = try await store.skillExecutionPolicy()
        XCTAssertEqual(defaultPolicy, SkillExecutionPolicy())

        try await store.setSkill(
            RecapDraftSkill.id,
            isEnabled: false,
            at: now)
        try await store.setAllSkillsPaused(
            true,
            at: now.addingTimeInterval(1))

        let paused = try await store.skillExecutionPolicy()
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.isEnabled(skillID: MeetingPackageExportSkill.id))
        XCTAssertFalse(paused.isIndividuallyEnabled(skillID: RecapDraftSkill.id))
        XCTAssertTrue(
            paused.isIndividuallyEnabled(skillID: MeetingPackageExportSkill.id),
            "pause must not destroy individual choices")

        try await store.setAllSkillsPaused(
            false,
            at: now.addingTimeInterval(2))
        let resumed = try await store.skillExecutionPolicy()
        XCTAssertFalse(resumed.isPaused)
        XCTAssertFalse(resumed.isEnabled(skillID: RecapDraftSkill.id))
        XCTAssertTrue(resumed.isEnabled(skillID: MeetingPackageExportSkill.id))
    }

    func testMissingOrInvalidControlStateFailsClosed() async throws {
        let store = try MeetingStore.inMemory()
        do {
            try await store.database.write { database in
                try database.execute(
                    sql: "UPDATE skillControl SET isPaused = 2 WHERE id = 1")
            }
            XCTFail("the schema must reject an invalid Boolean authority")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }

        try await store.database.write { database in
            try database.execute(sql: "DELETE FROM skillControl WHERE id = 1")
        }
        do {
            _ = try await store.skillExecutionPolicy()
            XCTFail("missing authority must not become an enabled default")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillControl",
                column: "id",
                value: "missing singleton") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testStorageRejectsUnboundedReceiptReadsAndMalformedSkillIDs() async throws {
        let store = try MeetingStore.inMemory()
        let zero = try await store.recentSkillExecutions(limit: 0)
        let oversized = try await store.recentSkillExecutions(limit: 101)
        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(oversized.isEmpty)

        do {
            try await store.setSkill(" recap-draft ", isEnabled: false)
            XCTFail("policy identities must be exact catalogue keys")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillDisablement",
                column: "skillID",
                value: " recap-draft ") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testControlCenterProjectsAvailabilityAndBoundsNewestReceipts() async throws {
        let store = try MeetingStore.inMemory()
        var newestProposalIDs: [UUID] = []

        for index in 0..<25 {
            let proposalID = UUID()
            let timestamp = now.addingTimeInterval(TimeInterval(index))
            _ = try await store.confirmSkillExecution(
                proposalID: proposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                idempotencyKey: "receipt-\(index)",
                at: timestamp)
            _ = try await store.beginSkillExecution(
                proposalID: proposalID,
                at: timestamp)
            _ = try await store.settleSkillExecution(
                proposalID: proposalID,
                succeeded: true,
                failureCategory: nil,
                at: timestamp)
            newestProposalIDs.insert(proposalID, at: 0)
        }

        let snapshot = try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(receiptLimit: 3))

        XCTAssertFalse(snapshot.isPaused)
        XCTAssertEqual(snapshot.receipts.map(\.proposalID), Array(newestProposalIDs.prefix(3)))
        XCTAssertEqual(snapshot.receipts.map(\.state), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(
            snapshot.skills.filter { $0.availability == .available }.map(\.id),
            [RecapDraftSkill.id, MeetingPackageExportSkill.id])
        XCTAssertEqual(
            snapshot.skills.filter { $0.availability == .planned }.map(\.id),
            [ReminderDraftSkill.id, PreMeetingBriefSkill.id])
        XCTAssertTrue(snapshot.skills.allSatisfy(\.isEnabled))
    }

    func testReceiptLimitIsClampedBeforeTheStoreRead() async throws {
        let store = RecordingSkillControlStore()

        _ = try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(receiptLimit: .max))

        let requestedLimits = await store.requestedLimits
        XCTAssertEqual(
            requestedLimits,
            [SkillControlCenterSnapshot.maximumReceiptLimit])
    }

    func testOnlyAvailableKnownSkillsCanBeChanged() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        let manager = ManageSkillControl(store: store, now: { instant })

        let unknown = try await manager.execute(.setSkillEnabled(
            skillID: "not-in-the-catalogue",
            isEnabled: false))
        let unavailable = try await manager.execute(.setSkillEnabled(
            skillID: ReminderDraftSkill.id,
            isEnabled: false))
        let updated = try await manager.execute(.setSkillEnabled(
            skillID: RecapDraftSkill.id,
            isEnabled: false))
        XCTAssertEqual(unknown, .rejected(.unknownSkill))
        XCTAssertEqual(unavailable, .rejected(.unavailableSkill))
        XCTAssertEqual(updated, .updated)

        let policy = try await store.skillExecutionPolicy()
        XCTAssertEqual(policy.disabledSkillIDs, [RecapDraftSkill.id])
    }

    func testRecentReceiptQueryHasItsDedicatedIndex() async throws {
        let store = try MeetingStore.inMemory()
        try await store.database.read { database in
            let plan = try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, attempt, updatedAt
                    FROM skillExecutionState
                    ORDER BY updatedAt DESC, proposalID ASC
                    LIMIT 20
                    """).map { $0["detail"] as String }
            XCTAssertTrue(
                plan.contains(where: {
                    $0.contains("USING INDEX skillExecutionState_on_recent")
                }),
                "the bounded receipt read must use its ordering index: \(plan)")
            XCTAssertFalse(
                plan.contains(where: { $0.contains("TEMP B-TREE") }),
                "the bounded receipt read must not sort the full history: \(plan)")
        }
    }

    func testReceiptDecoderRejectsMalformedPersistedProposalIdentity() throws {
        let database = try DatabaseQueue()
        let row = try database.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT 'not-a-uuid' AS proposalID,
                           'recap-draft' AS skillID,
                           1 AS skillVersion,
                           'key' AS idempotencyKey,
                           'succeeded' AS state,
                           1 AS attempt,
                           ? AS updatedAt
                    """,
                arguments: [now])
        }
        let persisted = try XCTUnwrap(row)

        XCTAssertThrowsError(
            try MeetingStore.skillExecutionRecord(from: persisted)
        ) { error in
            guard case StorageError.invalidPersistedUUID(
                table: "skillExecutionState",
                column: "proposalID",
                value: "not-a-uuid") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }
}

private actor RecordingSkillControlStore: SkillControlCenterStore {
    private(set) var requestedLimits: [Int] = []

    func skillExecutionPolicy() -> SkillExecutionPolicy {
        SkillExecutionPolicy()
    }

    func recentSkillExecutions(limit: Int) -> [SkillExecutionRecord] {
        requestedLimits.append(limit)
        return []
    }

    func setAllSkillsPaused(_ isPaused: Bool, at timestamp: Date) {}

    func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date
    ) {}
}
