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
            XCTAssertEqual(StorageSchema.version, 41)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v41")
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

    func testV39AddsPartialIndexesForEveryDurableReviewScope() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v38")

        try migrator.migrate(database)

        try database.read { database in
            let indexSQL = try Row.fetchAll(
                database,
                sql: """
                    SELECT name, sql FROM sqlite_master
                    WHERE type = 'index'
                      AND name LIKE 'skillExecutionState_on_%'
                    """).reduce(into: [String: String]()) { result, row in
                        result[row["name"] as String] = row["sql"] as String
                    }
            XCTAssertTrue(indexSQL["skillExecutionState_on_waiting"]?
                .contains("WHERE state = 'confirmed'") == true)
            XCTAssertTrue(indexSQL["skillExecutionState_on_attention"]?
                .contains("WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')") == true)
            XCTAssertTrue(indexSQL["skillExecutionState_on_completed"]?
                .contains("WHERE state IN ('succeeded', 'cancelled')") == true)
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
            _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
                proposalID: proposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                subject: .calendarEvent("control-center-test-subject"),
                offerKey: "receipt-\(index)",
                idempotencyKey: "receipt-\(index)",
                occurredAt: timestamp))
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
        XCTAssertEqual(snapshot.receiptScope, .recent)
        XCTAssertEqual(snapshot.receiptLoadState, .verified)
        XCTAssertEqual(snapshot.receipts.map(\.proposalID), Array(newestProposalIDs.prefix(3)))
        XCTAssertEqual(snapshot.receipts.map(\.state), [.succeeded, .succeeded, .succeeded])
        XCTAssertTrue(snapshot.receipts.allSatisfy {
            $0.failureCategory == nil
        })
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

    func testReceiptReadFailurePreservesVerifiedPolicyAndHidesReceipts() async throws {
        let store = FailingSkillControlStore(failure: .receipts)

        let snapshot = try await LoadSkillControlCenter(store: store).execute(
            LoadSkillControlCenterRequest(receiptScope: .completed))

        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.receiptScope, .completed)
        XCTAssertEqual(snapshot.receiptLoadState, .unavailable)
        XCTAssertTrue(snapshot.receipts.isEmpty)
        XCTAssertFalse(
            try XCTUnwrap(snapshot.skills.first { $0.id == RecapDraftSkill.id })
                .isEnabled)
        XCTAssertTrue(
            try XCTUnwrap(snapshot.skills.first {
                $0.id == MeetingPackageExportSkill.id
            }).isEnabled)
    }

    func testPolicyReadFailureStillFailsTheWholeControlSnapshot() async {
        let store = FailingSkillControlStore(failure: .policy)

        do {
            _ = try await LoadSkillControlCenter(store: store).execute(
                LoadSkillControlCenterRequest(receiptScope: .waiting))
            XCTFail("missing policy authority must fail the whole snapshot")
        } catch let error as StubSkillControlStoreFailure {
            XCTAssertEqual(error, .policy)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReceiptCancellationNeverBecomesAnUnavailableSnapshot() async {
        let store = FailingSkillControlStore(failure: .receiptCancellation)

        do {
            _ = try await LoadSkillControlCenter(store: store).execute(
                LoadSkillControlCenterRequest(receiptScope: .waiting))
            XCTFail("cancellation must leave the structured task")
        } catch is CancellationError {
            // Expected: cancellation is control flow, not partial authority.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReceiptScopesStayBoundedOrderedAndFutureStateFailClosed() async throws {
        let store = try MeetingStore.inMemory()
        let waiting = UUID()
        let executing = UUID()
        let failed = UUID()
        let succeeded = UUID()
        let dismissed = UUID()
        let future = UUID()
        try await makeExecution(
            waiting, state: .confirmed, timestamp: now, store: store)
        try await makeExecution(
            executing,
            state: .executing,
            timestamp: now.addingTimeInterval(1),
            store: store)
        try await makeExecution(
            failed,
            state: .failed,
            timestamp: now.addingTimeInterval(2),
            store: store)
        try await makeExecution(
            succeeded,
            state: .succeeded,
            timestamp: now.addingTimeInterval(3),
            store: store)
        try await makeExecution(
            dismissed,
            state: .dismissed,
            timestamp: now.addingTimeInterval(4),
            store: store)
        try await makeExecution(
            future,
            state: .confirmed,
            timestamp: now.addingTimeInterval(5),
            store: store)
        try await store.database.write { database in
            try database.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET state = 'future-state'
                    WHERE proposalID = ?
                    """,
                arguments: [future.uuidString])
        }

        let recent = try await store.skillExecutions(scope: .recent, limit: 3)
        let waitingRows = try await store.skillExecutions(scope: .waiting, limit: 20)
        let attentionRows = try await store.skillExecutions(
            scope: .needsAttention,
            limit: 20)
        let completedRows = try await store.skillExecutions(
            scope: .completed,
            limit: 20)

        XCTAssertEqual(recent.map(\.proposalID), [future, dismissed, succeeded])
        XCTAssertEqual(waitingRows.map(\.proposalID), [waiting])
        XCTAssertEqual(attentionRows.map(\.proposalID), [future, failed, executing])
        XCTAssertEqual(attentionRows.map(\.state), [.executing, .failed, .executing])
        XCTAssertEqual(completedRows.map(\.proposalID), [dismissed, succeeded])
        XCTAssertEqual(completedRows.map(\.state), [.dismissed, .succeeded])
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
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "inspection-retry",
            idempotencyKey: "inspection-retry",
            occurredAt: now))
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
        XCTAssertEqual(inspection.skillID, PreMeetingBriefSkill.id)
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
        XCTAssertNil(inspection.failureCategory)
        XCTAssertEqual(inspection.contextAvailability, .residentMenuBar)
        XCTAssertEqual(inspection.recoveryAvailability, .unavailable)
        let contextNavigation = try await ResolveSkillReceiptContextDestination(
            store: store
        ).execute(proposalID)
        XCTAssertEqual(contextNavigation, .unavailable)
    }

    func testSuccessfulReceiptReturnsToSourceWhileSkillsAreDisabled() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let proposalID = UUID()
        let key = RecapDraftSkill.idempotencyKey(for: meeting.id)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .meeting(meeting.id),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(1))
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: true,
            failureCategory: nil,
            at: now.addingTimeInterval(2))
        try await store.setSkill(RecapDraftSkill.id, isEnabled: false, at: now)
        try await store.setAllSkillsPaused(true, at: now)
        let before = try await store.skillExecutionHistory(
            proposalID: proposalID)

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let navigation = try await ResolveSkillReceiptContextDestination(
            store: store
        ).execute(proposalID)
        let after = try await store.skillExecutionHistory(
            proposalID: proposalID)

        XCTAssertEqual(inspection.contextAvailability, .reviewInContext)
        XCTAssertEqual(inspection.recoveryAvailability, .unavailable)
        XCTAssertEqual(navigation, .destination(.meeting(meeting.id)))
        XCTAssertEqual(after, before, "source review must not mutate an execution")
    }

    func testRecoverableFailureResolvesOnlyItsOriginalContext() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let proposalID = UUID()
        let key = RecapDraftSkill.idempotencyKey(for: meeting.id)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .meeting(meeting.id),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(1))
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .recoverable,
            at: now.addingTimeInterval(2))
        let before = try await store.skillExecutionHistory(
            proposalID: proposalID)

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let navigation = try await ResolveSkillReceiptRecoveryDestination(
            store: store
        ).execute(proposalID)
        let contextNavigation = try await ResolveSkillReceiptContextDestination(
            store: store
        ).execute(proposalID)
        let after = try await store.skillExecutionHistory(
            proposalID: proposalID)

        XCTAssertEqual(inspection.failureCategory, .recoverable)
        XCTAssertEqual(inspection.contextAvailability, .unavailable)
        XCTAssertEqual(inspection.recoveryAvailability, .reviewInContext)
        XCTAssertEqual(navigation, .destination(.meeting(meeting.id)))
        XCTAssertEqual(contextNavigation, .unavailable)
        XCTAssertEqual(after, before, "navigation must not claim or retry an effect")
    }

    func testReceiptContextFailsClosedForDeletedOrStaleAuthority() async throws {
        let store = try MeetingStore.inMemory()
        let deletedMeeting = Meeting(title: "Deleted", startedAt: now)
        let staleMeeting = Meeting(title: "Stale", startedAt: now)
        try await store.save(deletedMeeting)
        try await store.save(staleMeeting)
        let deletedProposalID = UUID()
        let staleProposalID = UUID()

        for (proposalID, meeting) in [
            (deletedProposalID, deletedMeeting),
            (staleProposalID, staleMeeting)
        ] {
            let key = RecapDraftSkill.idempotencyKey(for: meeting.id)
            _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
                proposalID: proposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                subject: .meeting(meeting.id),
                offerKey: key,
                idempotencyKey: key,
                occurredAt: now))
            _ = try await store.beginSkillExecution(
                proposalID: proposalID,
                at: now.addingTimeInterval(1))
            _ = try await store.settleSkillExecution(
                proposalID: proposalID,
                succeeded: true,
                failureCategory: nil,
                at: now.addingTimeInterval(2))
        }

        try await store.delete(deletedMeeting.id)
        try await store.purge(deletedMeeting.id)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillExecutionState
                    SET skillVersion = ?
                    WHERE proposalID = ?
                    """,
                arguments: [RecapDraftSkill.version + 1, staleProposalID.uuidString])
        }

        for proposalID in [deletedProposalID, staleProposalID] {
            let inspection = try await LoadSkillReceiptInspection(store: store)
                .execute(proposalID)
            let navigation = try await ResolveSkillReceiptContextDestination(
                store: store
            ).execute(proposalID)
            XCTAssertEqual(inspection.contextAvailability, .unavailable)
            XCTAssertEqual(navigation, .unavailable)
        }
    }

    func testOutcomeUnknownFailureRequiresExternalVerification() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let proposalID = UUID()
        let key = SecretGistPublishSkill.idempotencyKey(for: meeting.id)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: SecretGistPublishSkill.id,
            skillVersion: SecretGistPublishSkill.version,
            subject: .meeting(meeting.id),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .external,
            at: now)

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let navigation = try await ResolveSkillReceiptRecoveryDestination(
            store: store
        ).execute(proposalID)

        XCTAssertEqual(inspection.recoveryAvailability, .verifyExternally)
        XCTAssertEqual(navigation, .unavailable)
    }

    func testCalendarRecoveryStaysOnItsResidentMenuBarSurface() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        let eventID = "opaque-calendar-event"
        let key = PreMeetingBriefSkill.idempotencyKey(forEvent: eventID)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version,
            subject: .calendarEvent(eventID),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .critical,
            at: now)

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let navigation = try await ResolveSkillReceiptRecoveryDestination(
            store: store
        ).execute(proposalID)
        XCTAssertEqual(inspection.recoveryAvailability, .residentMenuBar)
        XCTAssertEqual(navigation, .unavailable)
    }

    func testRecoveryFailsClosedWithoutCurrentSubjectOrPolicy() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let proposalID = UUID()
        let key = RecapDraftSkill.idempotencyKey(for: meeting.id)
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .meeting(meeting.id),
            offerKey: key,
            idempotencyKey: key,
            occurredAt: now))
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .recoverable,
            at: now)
        try await store.setSkill(RecapDraftSkill.id, isEnabled: false, at: now)

        var inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        var navigation = try await ResolveSkillReceiptRecoveryDestination(
            store: store
        ).execute(proposalID)
        XCTAssertEqual(inspection.recoveryAvailability, .unavailable)
        XCTAssertEqual(navigation, .unavailable)

        try await store.setSkill(RecapDraftSkill.id, isEnabled: true, at: now)
        try await store.database.write { database in
            try database.execute(
                sql: "DELETE FROM skillExecutionSubject WHERE proposalID = ?",
                arguments: [proposalID.uuidString])
        }
        inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        navigation = try await ResolveSkillReceiptRecoveryDestination(
            store: store
        ).execute(proposalID)
        XCTAssertEqual(inspection.recoveryAvailability, .unavailable)
        XCTAssertEqual(navigation, .unavailable)
    }

    func testWaitingReceiptRevocationAddsOneNoEffectTerminalEvent() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "revoke-waiting",
            idempotencyKey: "revoke-waiting",
            occurredAt: now))

        let revocationTime = now.addingTimeInterval(1)
        let revoked = try await RevokeWaitingSkillExecution(
            store: store,
            now: { revocationTime }
        ).execute(proposalID)
        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let repeated = try await RevokeWaitingSkillExecution(store: store)
            .execute(proposalID)

        XCTAssertEqual(revoked, .revoked)
        XCTAssertEqual(repeated, .unavailable)
        XCTAssertEqual(inspection.state, .dismissed)
        XCTAssertEqual(inspection.events.map(\.kind), [.confirmed, .cancelled])
        XCTAssertEqual(inspection.events.map(\.attempt), [1, 1])
        XCTAssertTrue(inspection.events.allSatisfy {
            $0.failureCategory == nil
        })
    }

    func testWaitingReceiptRevocationCannotCancelAfterBegin() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "already-began",
            idempotencyKey: "already-began",
            occurredAt: now))
        _ = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(1))

        let outcome = try await RevokeWaitingSkillExecution(store: store)
            .execute(proposalID)
        let history = try await store.skillExecutionHistory(
            proposalID: proposalID)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(history.map(\.kind), ["confirm", "begin"])
    }

    func testWaitingReceiptRevocationRejectsMismatchedSettlement() async {
        let proposalID = UUID()
        let mismatched = SkillExecutionRecord(
            proposalID: UUID(),
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "other-owner",
            state: .dismissed,
            failureCategory: nil,
            attempt: 1,
            updatedAt: now)
        let useCase = RevokeWaitingSkillExecution(
            store: StubWaitingSkillExecutionRevoker(
                admission: .alreadySettled(mismatched)))

        do {
            _ = try await useCase.execute(proposalID)
            XCTFail("a mismatched settled record must fail closed")
        } catch let error as WaitingSkillExecutionRevocationError {
            XCTAssertEqual(error, .inconsistentAuthority)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReceiptInspectionRejectsMissingOrInconsistentAuditEvidence() async throws {
        let proposalID = UUID()
        let record = SkillExecutionRecord(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            idempotencyKey: "inconsistent-inspection",
            state: .succeeded,
            failureCategory: nil,
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
            _ = try await ResolveSkillReceiptContextDestination(
                store: inconsistent
            ).execute(proposalID)
            XCTFail("source navigation must replay causal evidence")
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

    func testNonFailedReceiptInspectionDoesNotReadUnavailableExecutionPolicy() async throws {
        let proposalID = UUID()
        let store = StubSkillReceiptInspectionStore(
            audit: completedInspectionAudit(
                proposalID: proposalID,
                failureCategory: nil),
            policyResult: .failure(.unavailable))

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let policyReadCount = await store.policyReadCount

        XCTAssertEqual(inspection.state, .succeeded)
        XCTAssertEqual(inspection.contextAvailability, .reviewInContext)
        XCTAssertEqual(inspection.recoveryAvailability, .unavailable)
        XCTAssertEqual(
            policyReadCount,
            0,
            "historical evidence is independent from execution policy")
    }

    func testExternalFailureGuidanceDoesNotReadUnavailableExecutionPolicy() async throws {
        let proposalID = UUID()
        let store = StubSkillReceiptInspectionStore(
            audit: completedInspectionAudit(
                proposalID: proposalID,
                failureCategory: .external),
            policyResult: .failure(.unavailable))

        let inspection = try await LoadSkillReceiptInspection(store: store)
            .execute(proposalID)
        let policyReadCount = await store.policyReadCount

        XCTAssertEqual(inspection.state, .failed)
        XCTAssertEqual(inspection.contextAvailability, .unavailable)
        XCTAssertEqual(inspection.recoveryAvailability, .verifyExternally)
        XCTAssertEqual(
            policyReadCount,
            0,
            "outcome-unknown guidance must survive unrelated policy failure")
    }

    func testLocalFailureRecoveryStillFailsClosedWhenPolicyIsUnavailable() async {
        let proposalID = UUID()
        let store = StubSkillReceiptInspectionStore(
            audit: completedInspectionAudit(
                proposalID: proposalID,
                failureCategory: .recoverable),
            policyResult: .failure(.unavailable))

        do {
            _ = try await LoadSkillReceiptInspection(store: store)
                .execute(proposalID)
            XCTFail("local recovery must verify current execution policy")
        } catch let error as StubSkillReceiptPolicyFailure {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let policyReadCount = await store.policyReadCount
        XCTAssertEqual(policyReadCount, 1)
    }

    func testReceiptAuditRejectsUnknownPersistedFailureCategory() async throws {
        let store = try MeetingStore.inMemory()
        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "invalid-failure-category",
            idempotencyKey: "invalid-failure-category",
            occurredAt: now))
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
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "broken-inspection-chain",
            idempotencyKey: "broken-inspection-chain",
            occurredAt: now))
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
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "stale-inspection-tail",
            idempotencyKey: "stale-inspection-tail",
            occurredAt: now))
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
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "bounded-inspection",
            idempotencyKey: "bounded-inspection",
            occurredAt: now))
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
            LoadSkillControlCenterRequest(
                receiptScope: .needsAttention,
                receiptLimit: .max))

        let requests = await store.requests
        XCTAssertEqual(
            requests,
            [SkillControlCenterStoreRequest(
                scope: .needsAttention,
                limit: SkillControlCenterSnapshot.maximumReceiptLimit)])
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
            let cases = [
                ("", "skillExecutionState_on_recent"),
                ("WHERE state = 'confirmed'", "skillExecutionState_on_waiting"),
                (
                    "WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')",
                    "skillExecutionState_on_attention"
                ),
                (
                    "WHERE state IN ('succeeded', 'cancelled')",
                    "skillExecutionState_on_completed"
                )
            ]
            for (predicate, expectedIndex) in cases {
                let plan = try Row.fetchAll(
                    database,
                    sql: """
                    EXPLAIN QUERY PLAN
                    SELECT proposalID, skillID, skillVersion, idempotencyKey,
                           state, failureCategory, attempt, updatedAt
                    FROM skillExecutionState INDEXED BY \(expectedIndex)
                    \(predicate)
                    ORDER BY updatedAt DESC, proposalID ASC
                    LIMIT 20
                    """).map { $0["detail"] as String }
                XCTAssertTrue(
                    plan.contains(where: { $0.contains("USING INDEX \(expectedIndex)") }),
                    "the bounded receipt read must use \(expectedIndex): \(plan)")
                XCTAssertFalse(
                    plan.contains(where: { $0.contains("TEMP B-TREE") }),
                    "the bounded receipt read must not sort full history: \(plan)")
            }
        }
    }

    private func makeExecution(
        _ proposalID: UUID,
        state: SkillExecutionState,
        timestamp: Date,
        store: MeetingStore
    ) async throws {
        _ = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            subject: .calendarEvent("control-center-test-subject"),
            offerKey: "scope-\(proposalID.uuidString)",
            idempotencyKey: "scope-\(proposalID.uuidString)",
            occurredAt: timestamp))
        switch state {
        case .confirmed:
            break
        case .executing, .failed, .succeeded:
            _ = try await store.beginSkillExecution(
                proposalID: proposalID,
                at: timestamp)
            if state == .failed {
                _ = try await store.settleSkillExecution(
                    proposalID: proposalID,
                    succeeded: false,
                    failureCategory: .recoverable,
                    at: timestamp)
            } else if state == .succeeded {
                _ = try await store.settleSkillExecution(
                    proposalID: proposalID,
                    succeeded: true,
                    failureCategory: nil,
                    at: timestamp)
            }
        case .dismissed:
            _ = try await store.cancelSkillExecution(
                proposalID: proposalID,
                at: timestamp)
        case .proposed, .previewed:
            XCTFail("non-durable proposal states cannot seed receipt scope tests")
        }
    }

    private func completedInspectionAudit(
        proposalID: UUID,
        failureCategory: FailureCategory?
    ) -> SkillExecutionAudit {
        let state: SkillExecutionState = failureCategory == nil
            ? .succeeded
            : .failed
        let terminalKind = failureCategory == nil ? "succeed" : "fail"
        return SkillExecutionAudit(
            record: SkillExecutionRecord(
                proposalID: proposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                idempotencyKey: "policy-read-\(proposalID.uuidString)",
                state: state,
                failureCategory: failureCategory,
                attempt: 1,
                updatedAt: now.addingTimeInterval(2)),
            history: [
                SkillExecutionHistoryEntry(
                    kind: "confirm",
                    attempt: 1,
                    failureCategory: nil,
                    occurredAt: now),
                SkillExecutionHistoryEntry(
                    kind: "begin",
                    attempt: 1,
                    failureCategory: nil,
                    occurredAt: now.addingTimeInterval(1)),
                SkillExecutionHistoryEntry(
                    kind: terminalKind,
                    attempt: 1,
                    failureCategory: failureCategory,
                    occurredAt: now.addingTimeInterval(2))
            ],
            subject: .meeting(MeetingID(rawValue: UUID())))
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
                           NULL AS failureCategory,
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
    private(set) var requests: [SkillControlCenterStoreRequest] = []

    func skillExecutionPolicy() -> SkillExecutionPolicy {
        SkillExecutionPolicy()
    }

    func skillExecutions(
        scope: SkillExecutionReviewScope,
        limit: Int
    ) -> [SkillExecutionRecord] {
        requests.append(SkillControlCenterStoreRequest(
            scope: scope,
            limit: limit))
        return []
    }

    func setAllSkillsPaused(_ isPaused: Bool, at timestamp: Date) {}

    func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date
    ) {}
}

private enum StubSkillControlStoreFailure: Error, Equatable {
    case policy
    case receipts
    case receiptCancellation
}

private actor FailingSkillControlStore: SkillControlCenterStore {
    let failure: StubSkillControlStoreFailure

    init(failure: StubSkillControlStoreFailure) {
        self.failure = failure
    }

    func skillExecutionPolicy() throws -> SkillExecutionPolicy {
        if failure == .policy {
            throw StubSkillControlStoreFailure.policy
        }
        return SkillExecutionPolicy(
            isPaused: true,
            disabledSkillIDs: [RecapDraftSkill.id])
    }

    func skillExecutions(
        scope: SkillExecutionReviewScope,
        limit: Int
    ) throws -> [SkillExecutionRecord] {
        if failure == .receipts {
            throw StubSkillControlStoreFailure.receipts
        }
        if failure == .receiptCancellation {
            throw CancellationError()
        }
        return []
    }

    func setAllSkillsPaused(_ isPaused: Bool, at timestamp: Date) {}

    func setSkill(
        _ skillID: String,
        isEnabled: Bool,
        at timestamp: Date
    ) {}
}

private struct SkillControlCenterStoreRequest: Equatable, Sendable {
    let scope: SkillExecutionReviewScope
    let limit: Int
}

private actor StubSkillReceiptInspectionStore: SkillReceiptInspectionStore {
    let audit: SkillExecutionAudit?
    let policyResult: Result<SkillExecutionPolicy, StubSkillReceiptPolicyFailure>
    private(set) var policyReadCount = 0

    init(
        audit: SkillExecutionAudit?,
        policyResult: Result<
            SkillExecutionPolicy,
            StubSkillReceiptPolicyFailure
        > = .success(SkillExecutionPolicy())
    ) {
        self.audit = audit
        self.policyResult = policyResult
    }

    func skillExecutionAudit(
        proposalID: UUID
    ) -> SkillExecutionAudit? {
        audit?.record.proposalID == proposalID ? audit : nil
    }

    func skillExecutionPolicy() throws -> SkillExecutionPolicy {
        policyReadCount += 1
        return try policyResult.get()
    }
}

private enum StubSkillReceiptPolicyFailure: Error, Equatable {
    case unavailable
}

private struct StubWaitingSkillExecutionRevoker: WaitingSkillExecutionRevoking {
    let admission: SkillExecutionAdmission

    func cancelSkillExecution(
        proposalID: UUID,
        at now: Date
    ) -> SkillExecutionAdmission {
        admission
    }
}
