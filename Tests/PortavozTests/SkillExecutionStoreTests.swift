import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SkillExecutionStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() throws -> MeetingStore {
        try MeetingStore.inMemory()
    }

    private func confirm(
        _ store: MeetingStore,
        proposalID: UUID = UUID(),
        key: String = "reminder-draft:meeting-1",
        offerKey: String? = nil,
        subject: SkillSubject = .calendarEvent("storage-test-subject"),
        at when: Date? = nil
    ) async throws -> SkillExecutionAdmission {
        try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: "reminder-draft",
            skillVersion: 1,
            subject: subject,
            offerKey: offerKey ?? key,
            idempotencyKey: key,
            occurredAt: when ?? now))
    }

    // MARK: - Idempotency

    /// The point of the key: a retry of the same proposal must find the effect
    /// already claimed instead of creating a second claim on it.
    func testConfirmingTwiceReturnsTheSameClaim() async throws {
        let store = try store()
        let proposal = UUID()

        guard case .admitted(let first) = try await confirm(store, proposalID: proposal)
        else { return XCTFail("first confirmation must be admitted") }
        let second = try await confirm(store, proposalID: proposal)

        guard case .alreadySettled(let existing) = second else {
            return XCTFail("a repeat confirmation must not create a second claim")
        }
        XCTAssertEqual(existing.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(existing.attempt, 1)
        XCTAssertEqual(existing.state, .confirmed)
    }

    /// Two different proposals cannot both own one effect.
    func testASecondProposalCannotClaimAnOwnedIdempotencyKey() async throws {
        let store = try store()
        _ = try await confirm(store, proposalID: UUID(), key: "shared-effect")

        let other = try await confirm(store, proposalID: UUID(), key: "shared-effect")

        XCTAssertEqual(other, .rejected(.idempotencyKeyClaimed))
    }

    func testIdempotencyKeyResolvesItsOriginalProposalForReconstructedUI() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(
            store,
            proposalID: proposal,
            key: "recap-draft:retry")

        let owner = try await store.skillExecution(
            idempotencyKey: "recap-draft:retry")
        let missing = try await store.skillExecution(idempotencyKey: "missing")
        let invalid = try await store.skillExecution(idempotencyKey: " invalid ")

        XCTAssertEqual(owner?.proposalID, proposal)
        XCTAssertEqual(owner?.state, .confirmed)
        XCTAssertNil(missing)
        XCTAssertNil(invalid)
    }

    func testChangingTheKeyForOneProposalIsRejected() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal, key: "original")

        let swapped = try await confirm(store, proposalID: proposal, key: "different")

        XCTAssertEqual(swapped, .rejected(.idempotencyKeyClaimed))
    }

    func testConfirmationPersistsExactSubjectAndRejectsASubjectSwap() async throws {
        let store = try store()
        let proposalID = UUID()
        let original = SkillSubject.calendarEvent("opaque-event-1")
        _ = try await confirm(
            store,
            proposalID: proposalID,
            key: "subject-owned-effect",
            subject: original)

        let persisted = try await store.skillExecutionSubject(
            proposalID: proposalID)
        XCTAssertEqual(persisted, original)
        let swapped = try await confirm(
            store,
            proposalID: proposalID,
            key: "subject-owned-effect",
            subject: .calendarEvent("opaque-event-2"))
        XCTAssertEqual(swapped, .rejected(.invalidProposal))
        let unchanged = try await store.skillExecutionSubject(
            proposalID: proposalID)
        XCTAssertEqual(unchanged, original)
    }

    func testDeletingMeetingRemovesOnlyItsRecoverySubject() async throws {
        let store = try store()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let proposalID = UUID()
        _ = try await confirm(
            store,
            proposalID: proposalID,
            key: "meeting-subject-effect",
            subject: .meeting(meeting.id))

        try await store.database.write { database in
            try database.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [meeting.id.rawValue.uuidString])
        }

        let subject = try await store.skillExecutionSubject(
            proposalID: proposalID)
        let execution = try await store.skillExecution(
            idempotencyKey: "meeting-subject-effect")
        XCTAssertNil(subject)
        XCTAssertNotNil(execution)
    }

    func testClaimRequiresTheEffectSlotToBelongToItsOffer() async throws {
        let store = try store()

        let unrelated = try await confirm(
            store,
            key: "other-effect",
            offerKey: "reminder-draft:meeting-1")
        let reusable = try await confirm(
            store,
            key: "meeting-package-export:meeting-1:/tmp/export.portavoz",
            offerKey: "meeting-package-export:meeting-1")

        XCTAssertEqual(unrelated, .rejected(.invalidProposal))
        guard case .admitted = reusable else {
            return XCTFail("a destination-scoped slot must belong to its reusable offer")
        }
    }

    func testDismissedReusableOfferRejectsANewDestinationClaim() async throws {
        let store = try store()
        let offerKey = "meeting-package-export:meeting-1"
        try await store.dismissSkillOffer(
            offerKey: offerKey,
            skillID: MeetingPackageExportSkill.id,
            at: now)

        let claim = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: UUID(),
            skillID: MeetingPackageExportSkill.id,
            skillVersion: MeetingPackageExportSkill.version,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: offerKey,
            idempotencyKey: offerKey + ":/tmp/export.portavoz",
            occurredAt: now))

        XCTAssertEqual(claim, .rejected(.offerDismissed))
    }

    func testDismissalDoesNotStealAnAlreadyOwnedReusableEffect() async throws {
        let store = try store()
        let proposalID = UUID()
        let offerKey = "meeting-package-export:meeting-1"
        let effectKey = offerKey + ":/tmp/original.portavoz"
        let first = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: MeetingPackageExportSkill.id,
            skillVersion: MeetingPackageExportSkill.version,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: offerKey,
            idempotencyKey: effectKey,
            occurredAt: now))
        guard case .admitted(let owner) = first else {
            return XCTFail("the first confirmation must own its exact effect")
        }
        try await store.dismissSkillOffer(
            offerKey: offerKey,
            skillID: MeetingPackageExportSkill.id,
            at: now.addingTimeInterval(1))

        let repeated = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: MeetingPackageExportSkill.id,
            skillVersion: MeetingPackageExportSkill.version,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: offerKey,
            idempotencyKey: effectKey,
            occurredAt: now.addingTimeInterval(2)))
        let newDestination = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: UUID(),
            skillID: MeetingPackageExportSkill.id,
            skillVersion: MeetingPackageExportSkill.version,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: offerKey,
            idempotencyKey: offerKey + ":/tmp/new.portavoz",
            occurredAt: now.addingTimeInterval(2)))

        XCTAssertEqual(repeated, .alreadySettled(owner))
        XCTAssertEqual(newDestination, .rejected(.offerDismissed))
    }

    func testOpaqueOfferKeyBytesSurviveClaimAndOwnerResolution() async throws {
        let store = try store()
        let proposalID = UUID()
        let opaqueKey = "pre-meeting-brief:event-id-with-trailing-space "

        let claim = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: proposalID,
            skillID: PreMeetingBriefSkill.id,
            skillVersion: PreMeetingBriefSkill.version,
            subject: .calendarEvent("event-id-with-trailing-space "),
            offerKey: opaqueKey,
            idempotencyKey: opaqueKey,
            occurredAt: now))
        let owner = try await store.skillExecution(idempotencyKey: opaqueKey)

        guard case .admitted = claim else {
            return XCTFail("opaque provider bytes must not be normalized away")
        }
        XCTAssertEqual(owner?.proposalID, proposalID)
        XCTAssertEqual(owner?.idempotencyKey, opaqueKey)
    }

    // MARK: - Relaunch

    /// Crashing after the effect landed must not repeat it.
    func testASucceededExecutionIsNeverAdmittedAgain() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposal, succeeded: true, failureCategory: nil, at: now)

        let relaunch = try await store.beginSkillExecution(
            proposalID: proposal,
            at: now.addingTimeInterval(60))

        guard case .alreadySettled(let record) = relaunch else {
            return XCTFail("a succeeded effect must not run again")
        }
        XCTAssertEqual(record.state, .succeeded)
        XCTAssertEqual(record.attempt, 1)
    }

    /// Crashing *during* the run is the ambiguous case: the effect may or may
    /// not exist, so it must be surfaced for reconciliation rather than
    /// blindly repeated.
    func testAnInterruptedExecutionIsNotSilentlyRepeated() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)

        let relaunch = try await store.beginSkillExecution(
            proposalID: proposal,
            at: now.addingTimeInterval(60))

        guard case .alreadySettled(let record) = relaunch else {
            return XCTFail("an interrupted run must not be blindly repeated")
        }
        XCTAssertEqual(record.state, .executing)
    }

    // MARK: - Retry

    func testFailureAllowsOneRetryUnderANewAttempt() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: false,
            failureCategory: .recoverable,
            at: now)

        let retry = try await store.beginSkillExecution(
            proposalID: proposal,
            at: now.addingTimeInterval(5))

        guard case .admitted(let record) = retry else {
            return XCTFail("a recoverable failure must be retryable")
        }
        XCTAssertEqual(record.state, .executing)
        XCTAssertNil(record.failureCategory)
        XCTAssertEqual(record.attempt, 2, "a retry is a new attempt")
    }

    func testFailureCategoryProjectionTracksOnlyCurrentFailedState() async throws {
        let store = try store()
        let proposalID = UUID()
        _ = try await confirm(store, proposalID: proposalID)
        _ = try await store.beginSkillExecution(proposalID: proposalID, at: now)
        let failed = try await store.settleSkillExecution(
            proposalID: proposalID,
            succeeded: false,
            failureCategory: .degradable,
            at: now)
        guard case .admitted(let failedRecord) = failed else {
            return XCTFail("failure must settle")
        }
        XCTAssertEqual(failedRecord.failureCategory, .degradable)

        let retried = try await store.beginSkillExecution(
            proposalID: proposalID,
            at: now.addingTimeInterval(1))
        guard case .admitted(let retryRecord) = retried else {
            return XCTFail("failed execution must enter a new attempt")
        }
        XCTAssertNil(retryRecord.failureCategory)
    }

    // MARK: - Cancellation

    func testCancellationIsLegalOnlyBeforeTheRunBegins() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)

        let cancelled = try await store.cancelSkillExecution(
            proposalID: proposal, at: now)
        guard case .alreadySettled(let record) = cancelled else {
            return XCTFail("cancelling a confirmed execution must settle it")
        }
        XCTAssertEqual(record.state, .dismissed)

        // Terminally settled, not a caller error: `alreadySettled` tells the
        // caller not to run, where `rejected` could be mistaken for a
        // transient failure and retried.
        let startAfterCancel = try await store.beginSkillExecution(
            proposalID: proposal, at: now)
        guard case .alreadySettled(let settled) = startAfterCancel else {
            return XCTFail("a cancelled execution must never start")
        }
        XCTAssertEqual(settled.state, .dismissed)

        let running = UUID()
        _ = try await confirm(store, proposalID: running, key: "second-effect")
        _ = try await store.beginSkillExecution(proposalID: running, at: now)
        let cancelAfterStart = try await store.cancelSkillExecution(
            proposalID: running, at: now)
        XCTAssertEqual(
            cancelAfterStart,
            .rejected(.illegalTransition),
            "an execution past the handoff cannot be cancelled")
    }

    func testBeginAndWaitingRevocationHaveOneLinearizedWinner() async throws {
        let store = try store()
        let proposalID = UUID()
        _ = try await confirm(store, proposalID: proposalID)
        let transitionTime = now.addingTimeInterval(1)

        async let begin = store.beginSkillExecution(
            proposalID: proposalID,
            at: transitionTime)
        async let revoke = RevokeWaitingSkillExecution(
            store: store,
            now: { transitionTime }
        ).execute(proposalID)
        let outcome = try await (begin, revoke)
        let history = try await store.skillExecutionHistory(
            proposalID: proposalID)

        switch outcome {
        case (.admitted(let record), .unavailable):
            XCTAssertEqual(record.state, .executing)
            XCTAssertEqual(history.map(\.kind), ["confirm", "begin"])
        case (.alreadySettled(let record), .revoked):
            XCTAssertEqual(record.state, .dismissed)
            XCTAssertEqual(history.map(\.kind), ["confirm", "cancel"])
        default:
            XCTFail("begin and revoke produced incompatible outcomes: \(outcome)")
        }
    }

    // MARK: - Validation and audit

    func testUnknownAndMalformedInputAreRejected() async throws {
        let store = try store()
        let unknown = try await store.beginSkillExecution(
            proposalID: UUID(), at: now)
        XCTAssertEqual(unknown, .rejected(.unknownExecution))

        let blankKey = try await confirm(store, key: "   ")
        XCTAssertEqual(blankKey, .rejected(.invalidProposal))

        let blankSkill = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: UUID(),
            skillID: "",
            skillVersion: 1,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: "k",
            idempotencyKey: "k",
            occurredAt: now))
        XCTAssertEqual(blankSkill, .rejected(.invalidProposal))

        let badVersion = try await store.confirmSkillExecution(SkillExecutionConfirmation(
            proposalID: UUID(),
            skillID: "ok",
            skillVersion: 0,
            subject: .calendarEvent("storage-test-subject"),
            offerKey: "k2",
            idempotencyKey: "k2",
            occurredAt: now))
        XCTAssertEqual(badVersion, .rejected(.invalidProposal))
    }

    func testSettlementRequiresAConsistentOutcome() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)

        let successWithCategory = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: true,
            failureCategory: .recoverable,
            at: now)
        XCTAssertEqual(
            successWithCategory,
            .rejected(.illegalTransition),
            "success cannot carry a failure category")

        let failureWithoutCategory = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: false,
            failureCategory: nil,
            at: now)
        XCTAssertEqual(
            failureWithoutCategory,
            .rejected(.illegalTransition),
            "failure must name its category")
    }

    /// One auditable receipt per attempt, carrying a typed category and no
    /// message that could hold meeting content.
    func testHistoryRecordsEveryAttemptWithoutContent() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)
        _ = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: false,
            failureCategory: .external,
            at: now.addingTimeInterval(1))
        _ = try await store.beginSkillExecution(
            proposalID: proposal,
            at: now.addingTimeInterval(2))
        _ = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: true,
            failureCategory: nil,
            at: now.addingTimeInterval(3))

        let history = try await store.skillExecutionHistory(proposalID: proposal)

        XCTAssertEqual(
            history.map(\.kind),
            ["confirm", "begin", "fail", "begin", "succeed"])
        XCTAssertEqual(history.map(\.attempt), [1, 1, 1, 2, 2])
        XCTAssertEqual(
            history.compactMap(\.failureCategory),
            [.external],
            "only the failure carries a category, and it is typed")
    }

    /// The schema is the first line of defence against a state this build
    /// cannot interpret: the CHECK rejects it at write time, so no unparseable
    /// row can exist for a reader to guess at.
    ///
    /// The reader still defaults such a value to `.executing` rather than
    /// `.failed`, because `.failed` is the one state `begin` treats as
    /// retryable — if a later migration widens this CHECK, guessing wrong
    /// there would re-run an effect that may already exist. That default is
    /// unreachable today, which is exactly what this test pins.
    func testTheSchemaRejectsAStateThisBuildCannotInterpret() async throws {
        let store = try MeetingStore.inMemory()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)

        do {
            try await store.database.write { database in
                try database.execute(
                    sql: """
                        UPDATE skillExecutionState
                        SET state = 'awaiting-external-confirmation'
                        WHERE proposalID = ?
                        """,
                    arguments: [proposal.uuidString])
            }
            XCTFail("an unknown durable state must not be writable")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("CHECK constraint failed"),
                "the state column constrains its own vocabulary")
        }

        // The row is untouched, so the execution stays exactly as confirmed.
        let attempt = try await store.beginSkillExecution(
            proposalID: proposal,
            at: now)
        guard case .admitted(let record) = attempt else {
            return XCTFail("the confirmed execution is still runnable")
        }
        XCTAssertEqual(record.state, .executing)
    }

    // MARK: - Clock

    /// NTP can step the clock backwards. A settlement stamped before the row
    /// was created would fail the `updatedAt >= createdAt` CHECK and strand the
    /// execution in `executing` — the one state meaning "the effect may already
    /// have happened", so it could never be settled or retried.
    func testABackwardClockStepStillSettlesTheExecution() async throws {
        let store = try store()
        let proposal = UUID()
        _ = try await confirm(store, proposalID: proposal)
        _ = try await store.beginSkillExecution(proposalID: proposal, at: now)

        let backwards = now.addingTimeInterval(-3_600)
        let settled = try await store.settleSkillExecution(
            proposalID: proposal,
            succeeded: true,
            failureCategory: nil,
            at: backwards)

        guard case .admitted(let record) = settled else {
            return XCTFail("a backward clock step must not block settlement")
        }
        XCTAssertEqual(record.state, .succeeded)
        XCTAssertGreaterThanOrEqual(
            record.updatedAt,
            now,
            "the projection's updatedAt never moves backwards")

        // The event log keeps what the clock actually said, unclamped.
        let history = try await store.skillExecutionHistory(proposalID: proposal)
        XCTAssertEqual(history.last?.kind, "succeed")
        XCTAssertEqual(history.last?.occurredAt, backwards)
    }

    // MARK: - Migration

    func testV31MigratesAdditivelyToSkillExecutionSchema() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v30")

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 46)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v46")
            XCTAssertEqual(
                try Set(database.columns(in: "skillExecutionEvent").map(\.name)),
                [
                    "id", "proposalID", "previousEventID", "kind", "attempt",
                    "failureCategory", "occurredAt"
                ])
            XCTAssertEqual(
                try Set(database.columns(in: "skillExecutionState").map(\.name)),
                [
                    "proposalID", "skillID", "skillVersion", "idempotencyKey",
                    "state", "attempt", "latestEventID", "createdAt", "updatedAt",
                    "failureCategory"
                ])
            XCTAssertEqual(
                try Set(database.columns(in: "skillExecutionSubject").map(\.name)),
                [
                    "proposalID", "subjectKind", "meetingID", "commitmentID",
                    "calendarEventID"
                ])
        }
    }

    func testV41BackfillsFailureProjectionWithoutInventingLegacySubject() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v40")
        let proposalID = UUID()
        let eventID = UUID()
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionEvent (
                        id, proposalID, previousEventID, kind, attempt,
                        failureCategory, occurredAt
                    ) VALUES (?, ?, NULL, 'fail', 1, 'recoverable', ?)
                    """,
                arguments: [eventID.uuidString, proposalID.uuidString, now])
            try database.execute(
                sql: """
                    INSERT INTO skillExecutionState (
                        proposalID, skillID, skillVersion, idempotencyKey,
                        state, attempt, latestEventID, createdAt, updatedAt
                    ) VALUES (?, 'recap-draft', 1, 'legacy-effect',
                              'failed', 1, ?, ?, ?)
                    """,
                arguments: [
                    proposalID.uuidString,
                    eventID.uuidString,
                    now,
                    now
                ])
        }

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: """
                        SELECT failureCategory FROM skillExecutionState
                        WHERE proposalID = ?
                        """,
                    arguments: [proposalID.uuidString]),
                "recoverable")
            XCTAssertEqual(
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionSubject"),
                0,
                "v41 must never infer a subject from legacy key text")
        }
    }
}
