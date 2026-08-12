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
            XCTAssertEqual(StorageSchema.version, 38)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v38")
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
            [
                RecapDraftSkill.id,
                MeetingPackageExportSkill.id,
                ReminderDraftSkill.id,
                PreMeetingBriefSkill.id,
                EmailRecapDraftSkill.id,
                SecretGistPublishSkill.id
            ])
        XCTAssertEqual(
            snapshot.skills.filter { $0.availability == .planned }.map(\.id),
            [])
        XCTAssertTrue(snapshot.skills.allSatisfy(\.isEnabled))
    }

    func testControlCenterDerivesDisclosureFromExecutableCapabilities() async throws {
        let snapshot = try await LoadSkillControlCenter(
            store: try MeetingStore.inMemory()
        ).execute(LoadSkillControlCenterRequest())

        XCTAssertEqual(
            snapshot.skills.filter {
                $0.disclosureBoundary == .noDirectNetworkHandoff
            }.map(\.id),
            [
                RecapDraftSkill.id,
                MeetingPackageExportSkill.id,
                ReminderDraftSkill.id,
                PreMeetingBriefSkill.id
            ])
        XCTAssertEqual(
            snapshot.skills.filter {
                $0.disclosureBoundary == .externalHandoff
            }.map(\.id),
            [
                EmailRecapDraftSkill.id,
                SecretGistPublishSkill.id
            ])
        XCTAssertTrue(snapshot.skills.allSatisfy {
            $0.definition.confirmationPolicy == .explicitPerProposal
        })
    }

    func testReceiptInspectionProjectsRetryAsOneCausalContentFreeTimeline() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "inspection-retry",
            at: now)
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(1))
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .recoverable,
            at: now.addingTimeInterval(2))
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(3))
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: true,
            failureCategory: nil,
            at: now.addingTimeInterval(4))

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)

        XCTAssertEqual(inspection.proposalID, proposalID)
        XCTAssertEqual(inspection.skillID, RecapDraftSkill.id)
        XCTAssertEqual(inspection.state, .succeeded)
        XCTAssertEqual(inspection.attempt, 2)
        XCTAssertEqual(inspection.events.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(
            inspection.events.map(\.kind),
            [.confirmed, .started, .failed, .started, .succeeded])
        XCTAssertEqual(
            inspection.events.map(\.attempt),
            [1, 1, 1, 2, 2])
        XCTAssertEqual(
            inspection.events.map(\.failureCategory),
            [nil, nil, .recoverable, nil, nil])
    }

    func testReceiptInspectionRejectsMissingOrInconsistentAuditEvidence() async throws {
        let proposalID = UUID()
        let record = SkillExecutionRecord(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "inconsistent-inspection",
            state: .succeeded,
            attempt: 1,
            updatedAt: now)
        let inconsistent = StubSkillReceiptInspectionStore(audit: SkillExecutionAudit(
            record: record,
            history: [SkillExecutionHistoryEntry(
                kind: "confirm",
                attempt: 1,
                failureCategory: nil,
                occurredAt: now)]))

        do {
            _ = try await LoadSkillReceiptInspection(store: inconsistent)
                .execute(proposalID)
            XCTFail("a terminal state needs matching append-only evidence")
        } catch let error as SkillReceiptInspectionError {
            XCTAssertEqual(error, .inconsistentHistory)
        }

        do {
            _ = try await LoadSkillReceiptInspection(
                store: StubSkillReceiptInspectionStore(audit: nil)
            ).execute(proposalID)
            XCTFail("a removed receipt must not produce invented history")
        } catch let error as SkillReceiptInspectionError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testReceiptAuditRejectsUnknownPersistedFailureCategory() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "invalid-failure-category",
            at: now)
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .recoverable,
            at: now)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillExecutionEvent
                    SET failureCategory = 'unknown-category'
                    WHERE proposalID = ? AND kind = 'fail'
                    """,
                arguments: [proposalID.uuidString])
        }

        do {
            _ = try await store.skillExecutionAudit(proposalID: proposalID)
            XCTFail("audit evidence must not silently erase an unknown category")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillExecutionEvent",
                column: "failureCategory",
                value: "unknown-category") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testReceiptAuditRejectsABrokenPredecessorChain() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "broken-inspection-chain",
            at: now)
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: true,
            failureCategory: nil,
            at: now)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillExecutionEvent
                    SET previousEventID = NULL
                    WHERE proposalID = ? AND kind = 'begin'
                    """,
                arguments: [proposalID.uuidString])
        }

        do {
            _ = try await store.skillExecutionAudit(proposalID: proposalID)
            XCTFail("receipt inspection must verify predecessor linkage")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillExecutionEvent",
                column: "previousEventID",
                value: "missing") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testReceiptAuditRejectsAProjectionTailBehindTheEventChain() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "stale-inspection-tail",
            at: now)
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: true,
            failureCategory: nil,
            at: now)
        let staleEventIDRead = try await store.database.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT id FROM skillExecutionEvent
                    WHERE proposalID = ?
                    ORDER BY rowid ASC
                    LIMIT 1
                    """,
                arguments: [proposalID.uuidString])
        }
        let staleEventID = try XCTUnwrap(staleEventIDRead)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET latestEventID = ?
                    WHERE proposalID = ?
                    """,
                arguments: [staleEventID, proposalID.uuidString])
        }

        do {
            _ = try await store.skillExecutionAudit(proposalID: proposalID)
            XCTFail("receipt inspection must reject a stale projection tail")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillExecutionState",
                column: "latestEventID",
                value: staleEventID) = error
            else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testReceiptAuditRefusesToMaterializeAnUnboundedRetryHistory() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "bounded-inspection",
            at: now)
        for attempt in 1...128 {
            let timestamp = now.addingTimeInterval(TimeInterval(attempt))
            _ = try await store.beginSkillExecution(
                proposalID: proposalID,
                at: timestamp)
            _ = try await store.settleSkillExecution(
                proposalID: proposalID,
                succeeded: false,
                failureCategory: .recoverable,
                at: timestamp)
        }

        do {
            _ = try await store.skillExecutionAudit(proposalID: proposalID)
            XCTFail("receipt inspection must not materialize an unbounded chain")
        } catch let error as StorageError {
            guard case .invalidPersistedValue(
                table: "skillExecutionEvent",
                column: "proposalID",
                value: "history exceeds inspection limit") = error
            else { return XCTFail("unexpected error: \(error)") }
        }
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

    func testOnlyKnownAvailableSkillsCanBeChanged() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        let manager = ManageSkillControl(store: store, now: { instant })

        let unknown = try await manager.execute(.setSkillEnabled(
            skillID: "not-in-the-catalogue",
            isEnabled: false))
        let reminderUpdated = try await manager.execute(.setSkillEnabled(
            skillID: ReminderDraftSkill.id,
            isEnabled: false))
        let emailUpdated = try await manager.execute(.setSkillEnabled(
            skillID: EmailRecapDraftSkill.id,
            isEnabled: false))
        let gistUpdated = try await manager.execute(.setSkillEnabled(
            skillID: SecretGistPublishSkill.id,
            isEnabled: false))
        let updated = try await manager.execute(.setSkillEnabled(
            skillID: RecapDraftSkill.id,
            isEnabled: false))
        XCTAssertEqual(unknown, .rejected(.unknownSkill))
        XCTAssertEqual(reminderUpdated, .updated)
        XCTAssertEqual(emailUpdated, .updated)
        XCTAssertEqual(gistUpdated, .updated)
        XCTAssertEqual(updated, .updated)

        let policy = try await store.skillExecutionPolicy()
        XCTAssertEqual(
            policy.disabledSkillIDs,
            [
                EmailRecapDraftSkill.id,
                RecapDraftSkill.id,
                ReminderDraftSkill.id,
                SecretGistPublishSkill.id
            ])
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

private actor StubSkillReceiptInspectionStore: SkillReceiptInspectionStore {
    let audit: SkillExecutionAudit?

    init(audit: SkillExecutionAudit?) {
        self.audit = audit
    }

    func skillExecutionAudit(
        proposalID: UUID
    ) -> SkillExecutionAudit? {
        audit?.record.proposalID == proposalID ? audit : nil
    }
}
