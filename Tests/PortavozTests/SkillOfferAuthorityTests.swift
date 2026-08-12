import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class SkillOfferAuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testV40AddsContentFreeProposalAuthorityAndWidensDismissalIdentity() throws {
        let database = try DatabaseQueue()
        let migrator = StorageSchema.migrator()
        try migrator.migrate(database, upTo: "v39")
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO skillOfferDismissal (offerKey, skillID, dismissedAt)
                    VALUES ('old-offer', 'recap-draft', ?)
                    """,
                arguments: [now])
        }

        try migrator.migrate(database)

        try database.read { database in
            XCTAssertEqual(StorageSchema.version, 40)
            XCTAssertEqual(
                try String.fetchAll(
                    database,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                "v40")
            XCTAssertEqual(
                try Set(database.columns(in: "skillOfferProposal").map(\.name)),
                [
                    "offerKey", "reviewID", "skillID", "skillVersion", "reason",
                    "subjectKind", "meetingID", "commitmentID", "calendarEventID",
                    "proposedAt", "lastObservedAt", "expiresAt"
                ])
            XCTAssertEqual(
                try Set(database.columns(in: "skillOfferProposalInput").map(\.name)),
                ["offerKey", "dataClass"])
            XCTAssertEqual(
                try String.fetchOne(
                    database,
                    sql: "SELECT offerKey FROM skillOfferDismissal"),
                "old-offer")
            let columns = try ["skillOfferProposal", "skillOfferProposalInput"]
                .flatMap { try database.columns(in: $0).map(\.name) }
            for forbidden in ["title", "preview", "transcript", "destination", "recipient"] {
                XCTAssertFalse(columns.contains(forbidden))
            }
        }
    }

    func testValidMaximumEventIdentityCanBeDurablyDismissed() async throws {
        let store = try MeetingStore.inMemory()
        let identifier = String(repeating: "é", count: 999) + "x "
        XCTAssertEqual(identifier.utf8.count, UpcomingEvent.maximumIdentifierLength)
        let event = UpcomingEvent(
            id: identifier,
            title: "Never persisted",
            startDate: now.addingTimeInterval(3_600),
            attendees: [])
        let instant = now
        let useCase = LoadPreMeetingBriefOffer(store: store, now: { instant })
        let loaded = try await useCase.execute(event)
        let offer = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(offer.offerKey.utf8.count, 200)

        try await DismissPreMeetingBriefOffer(
            store: store,
            now: { instant }).execute(offer)

        let dismissedOffer = try await useCase.execute(event)
        XCTAssertNil(dismissedOffer)
        let dismissals = try await store.dismissedSkillOffers(
            offerKeys: [offer.offerKey])
        XCTAssertEqual(dismissals, [offer.offerKey])
    }

    func testMeetingProducerPersistsTypedWhyAndExactInputClasses() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Never returned to Settings", startedAt: now)
        try await store.save(meeting)
        let observedAt = now.addingTimeInterval(10)

        let offers = try await LoadMeetingSkillOffers(
            store: store,
            now: { observedAt }).execute(LoadMeetingSkillOffersRequest(
                meetingID: meeting.id,
                hasSummary: true))
        let review = try await LoadSkillOfferReview(
            store: store,
            now: { observedAt }).execute(LoadSkillOfferReviewRequest())

        XCTAssertEqual(review.offers.count, offers.count)
        XCTAssertEqual(Set(review.offers.map(\.reason)), [.meetingSummaryReady])
        XCTAssertTrue(review.offers.allSatisfy {
            $0.inputDataClasses.contains(.meetingSummary)
                && $0.proposedAt == observedAt
                && $0.lastObservedAt == observedAt
        })
        XCTAssertEqual(
            review.offers.first(where: {
                $0.skillID == MeetingPackageExportSkill.id
            })?.inputDataClasses,
            MeetingPackageExportSkill.definition.inputDataClasses)
    }

    func testOpaqueReviewResolvesOnlyAnInertMeetingDestination() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Never returned to Settings", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .emailRecapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let instant = now
        let review = try await LoadSkillOfferReview(
            store: store,
            now: { instant }).execute(LoadSkillOfferReviewRequest())
        let reviewID = try XCTUnwrap(review.offers.first?.id)

        let outcome = try await ResolveSkillOfferReviewDestination(
            store: store,
            now: { instant }).execute(reviewID)
        let executionRowCounts = try await store.database.read { database in
            (
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionState") ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM skillExecutionEvent") ?? -1
            )
        }

        XCTAssertEqual(outcome, .destination(.meeting(meeting.id)))
        XCTAssertEqual(executionRowCounts.0, 0)
        XCTAssertEqual(executionRowCounts.1, 0)
    }

    func testOpaqueReviewMapsCommitmentAndCalendarToOwnedSurfaces() async throws {
        let store = try MeetingStore.inMemory()
        let commitmentEnvelope = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Never returned to Settings",
                assignee: .me,
                origin: .manual(meetingID: nil)),
            at: now)
        let reminder = try XCTUnwrap(ReminderDraftOffer(
            commitment: commitmentEnvelope.commitment))
        let event = UpcomingEvent(
            id: "opaque-calendar-route",
            title: "Never persisted",
            startDate: now.addingTimeInterval(3_600),
            attendees: [])
        let brief = try XCTUnwrap(PreMeetingBriefOffer(event: event))
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [reminder.offerKey, brief.offerKey],
            active: [
                reminder.registration(at: now),
                brief.registration(at: now.addingTimeInterval(1))
            ])
        let instant = now
        let review = try await LoadSkillOfferReview(
            store: store,
            now: { instant }).execute(LoadSkillOfferReviewRequest())
        let reminderID = try XCTUnwrap(review.offers.first(where: {
            $0.skillID == ReminderDraftSkill.id
        })?.id)
        let briefID = try XCTUnwrap(review.offers.first(where: {
            $0.skillID == PreMeetingBriefSkill.id
        })?.id)

        let reminderDestination = try await ResolveSkillOfferReviewDestination(
            store: store,
            now: { instant }).execute(reminderID)
        let briefDestination = try await ResolveSkillOfferReviewDestination(
            store: store,
            now: { instant }).execute(briefID)

        XCTAssertEqual(
            reminderDestination,
            .destination(.commitment(commitmentEnvelope.commitment.id)))
        XCTAssertEqual(briefDestination, .destination(.residentMenuBar))
    }

    func testReviewDestinationFailsClosedWhenAuthorityChanges() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let reviews = try await store.proposedSkillOffers(
            limit: 1,
            at: now)
        let reviewID = try XCTUnwrap(reviews.first?.id)
        let instant = now
        let resolve = ResolveSkillOfferReviewDestination(
            store: store,
            now: { instant })

        try await store.setAllSkillsPaused(true, at: now)
        let paused = try await resolve.execute(reviewID)
        XCTAssertEqual(paused, .unavailable)
        try await store.setAllSkillsPaused(false, at: now)
        try await store.setSkill(offer.skillID, isEnabled: false, at: now)
        let disabled = try await resolve.execute(reviewID)
        XCTAssertEqual(disabled, .unavailable)
        try await store.setSkill(offer.skillID, isEnabled: true, at: now)
        _ = try await store.dismissProposedSkillOffer(
            reviewID: reviewID,
            at: now)
        let dismissed = try await resolve.execute(reviewID)
        XCTAssertEqual(dismissed, .unavailable)
    }

    func testReviewDestinationRejectsMismatchedPersistedSkillAuthority() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let reviews = try await store.proposedSkillOffers(
            limit: 1,
            at: now)
        let reviewID = try XCTUnwrap(reviews.first?.id)
        try await store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE skillOfferProposal
                    SET skillID = ?
                    WHERE reviewID = ?
                    """,
                arguments: [ReminderDraftSkill.id, reviewID.uuidString])
        }
        let instant = now

        do {
            _ = try await ResolveSkillOfferReviewDestination(
                store: store,
                now: { instant }).execute(reviewID)
            XCTFail("mismatched Skill and subject authority must fail closed")
        } catch let error as SkillOfferReviewError {
            XCTAssertEqual(error, .invalidAuthority)
        }
    }

    func testConfirmationAndDismissalAtomicallyRetireExactOffers() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let recap = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        let package = MeetingSkillOffer(kind: .packageExport, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [recap.offerKey, package.offerKey],
            active: [
                recap.registration(at: now),
                package.registration(at: now.addingTimeInterval(1))
            ])

        let proposalID = UUID()
        _ = try await store.confirmSkillExecution(
            proposalID: proposalID,
            skillID: RecapDraftSkill.id,
            skillVersion: RecapDraftSkill.version,
            offerKey: recap.offerKey,
            idempotencyKey: recap.offerKey,
            at: now.addingTimeInterval(2))
        let afterConfirmation = try await store.proposedSkillOffers(
            limit: 20,
            at: now)
        XCTAssertEqual(
            afterConfirmation.map(\.skillID),
            [MeetingPackageExportSkill.id])

        try await store.dismissSkillOffer(
            offerKey: package.offerKey,
            skillID: package.skillID,
            at: now.addingTimeInterval(3))
        let afterDismissal = try await store.proposedSkillOffers(
            limit: 20,
            at: now)
        XCTAssertTrue(afterDismissal.isEmpty)
    }

    func testOpaqueReviewDismissalWinsAgainstAStaleSurfaceAndExecution() async throws {
        let store = try MeetingStore.inMemory()
        let instant = now
        let meeting = Meeting(title: "Never returned", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let review = try await LoadSkillOfferReview(
            store: store,
            now: { instant }).execute(LoadSkillOfferReviewRequest())
        let opaqueID = try XCTUnwrap(review.offers.first?.id)
        let built = MeetingSkillProposalFactory.recapProposal(
            meetingID: meeting.id,
            at: now)
        let effect = RecordingSkillEffect()

        let dismissed = try await DismissSkillOfferReview(
            store: store,
            now: { instant.addingTimeInterval(1) }).execute(opaqueID)
        XCTAssertEqual(dismissed, .dismissed)

        // A producer that read before the dismissal can reconcile afterwards.
        // The tombstone must still win rather than recreating hidden authority.
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now.addingTimeInterval(2))])
        let reviews = try await store.proposedSkillOffers(
            limit: 20,
            at: now.addingTimeInterval(2))
        XCTAssertTrue(reviews.isEmpty)
        let proposalCount = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM skillOfferProposal") ?? -1
        }
        XCTAssertEqual(proposalCount, 0)

        // An already-open confirmation owns a valid proposal snapshot, but it
        // is not authority after the central dismissal committed.
        let execution = try await ExecuteSkill(
            claims: store,
            policy: store,
            effects: [RecapDraftSkill.id: effect],
            now: { instant.addingTimeInterval(3) }
        ).execute(ExecuteSkillRequest(
            proposal: built.proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            offerKey: offer.offerKey,
            idempotencyKey: built.idempotencyKey))
        XCTAssertEqual(execution, .rejected(.offerDismissed))
        let executionCount = await effect.executionCount
        let history = try await store.skillExecutionHistory(
            proposalID: built.proposal.id)
        XCTAssertEqual(executionCount, 0)
        XCTAssertTrue(history.isEmpty)

        let repeated = try await DismissSkillOfferReview(
            store: store,
            now: { instant.addingTimeInterval(4) }).execute(opaqueID)
        XCTAssertEqual(repeated, .unavailable)
    }

    func testExpiredOpaqueReviewIsRemovedWithoutInventingADismissal() async throws {
        let store = try MeetingStore.inMemory()
        let event = UpcomingEvent(
            id: "expired-review",
            title: "Never persisted",
            startDate: now.addingTimeInterval(10),
            attendees: [])
        let offer = try XCTUnwrap(PreMeetingBriefOffer(event: event))
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let review = try await store.proposedSkillOffers(
            limit: 1,
            at: now)
        let reviewID = try XCTUnwrap(review.first?.id)

        let resolution = try await ResolveSkillOfferReviewDestination(
            store: store,
            now: { event.startDate }).execute(reviewID)
        let outcome = try await store.dismissProposedSkillOffer(
            reviewID: reviewID,
            at: event.startDate)

        XCTAssertEqual(resolution, .unavailable)
        XCTAssertEqual(outcome, .unavailable)
        let dismissals = try await store.dismissedSkillOffers(
            offerKeys: [offer.offerKey])
        let remaining = try await store.proposedSkillOffers(
            limit: 1,
            at: event.startDate)
        XCTAssertTrue(dismissals.isEmpty)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testExpiredOffersArePrunedBeforeTheBoundedReview() async throws {
        let store = try MeetingStore.inMemory()
        let event = UpcomingEvent(
            id: "opaque-expired-event",
            title: "Never persisted",
            startDate: now.addingTimeInterval(-1),
            attendees: [])
        let offer = try XCTUnwrap(PreMeetingBriefOffer(event: event))
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])

        let review = try await store.proposedSkillOffers(limit: 20, at: now)
        XCTAssertTrue(review.isEmpty)
        let count = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM skillOfferProposal") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testSameVersionCannotSilentlyChangeItsInputExplanation() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let drifted = SkillOfferRegistration(
            offerKey: offer.offerKey,
            definition: offer.definition,
            requestedInputDataClasses: [.meetingSummary],
            subject: .meeting(meeting.id),
            reason: .meetingSummaryReady,
            proposedAt: now.addingTimeInterval(1))

        do {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: [offer.offerKey],
                active: [drifted])
            XCTFail("one version cannot rewrite the explanation after review")
        } catch let error as StorageError {
            guard case .invalidSkillOffer = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testReconciliationBoundsRejectBeforeAnyPartialWrite() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)

        do {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: [offer.offerKey, offer.offerKey],
                active: [offer.registration(at: now)])
            XCTFail("duplicate candidate authority must be rejected")
        } catch let error as StorageError {
            guard case .invalidSkillOffer = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let oversized = (0...MeetingStore.maximumSkillOfferReconciliationCount)
            .map { "bounded-offer-\($0)" }
        do {
            try await store.reconcileSkillOffers(
                candidateOfferKeys: oversized,
                active: [])
            XCTFail("an oversized reconciliation must be rejected")
        } catch let error as StorageError {
            guard case .invalidSkillOffer = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let count = try await store.database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM skillOfferProposal") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testReviewRejectsAnOfferFromAnUnknownCatalogueVersion() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let current = RecapDraftSkill.definition
        let future = SkillDefinition(
            id: current.id,
            version: current.version + 1,
            capabilities: current.capabilities,
            inputDataClasses: current.inputDataClasses,
            confirmationPolicy: current.confirmationPolicy)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        let registration = SkillOfferRegistration(
            offerKey: offer.offerKey,
            definition: future,
            requestedInputDataClasses: future.inputDataClasses,
            subject: .meeting(meeting.id),
            reason: .meetingSummaryReady,
            proposedAt: now)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [registration])

        let instant = now
        do {
            _ = try await LoadSkillOfferReview(
                store: store,
                now: { instant }).execute(LoadSkillOfferReviewRequest())
            XCTFail("an unknown Skill version must not reach Settings")
        } catch let error as SkillOfferReviewError {
            XCTAssertEqual(error, .invalidAuthority)
        }
    }

    func testReobservationKeepsReviewIdentityAndSubjectDeletionCascades() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private", startedAt: now)
        try await store.save(meeting)
        let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: now)])
        let firstRows = try await store.proposedSkillOffers(limit: 1, at: now)
        let first = try XCTUnwrap(firstRows.first)

        let later = now.addingTimeInterval(60)
        try await store.reconcileSkillOffers(
            candidateOfferKeys: [offer.offerKey],
            active: [offer.registration(at: later)])
        let secondRows = try await store.proposedSkillOffers(limit: 1, at: later)
        let second = try XCTUnwrap(secondRows.first)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.proposedAt, first.proposedAt)
        XCTAssertEqual(second.lastObservedAt, later)

        try await store.database.write { database in
            try database.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [meeting.id.rawValue.uuidString])
        }
        let afterDeletion = try await store.proposedSkillOffers(
            limit: 1,
            at: later)
        XCTAssertTrue(afterDeletion.isEmpty)
    }

    func testReviewIsBoundedPolicyAwareAndUsesNewestFirstIndex() async throws {
        let store = try MeetingStore.inMemory()
        var registrations: [SkillOfferRegistration] = []
        var keys: [String] = []
        for index in 0..<25 {
            let meeting = Meeting(
                title: "Private \(index)",
                startedAt: now.addingTimeInterval(TimeInterval(index)))
            try await store.save(meeting)
            let offer = MeetingSkillOffer(kind: .recapDraft, meetingID: meeting.id)
            keys.append(offer.offerKey)
            registrations.append(offer.registration(
                at: now.addingTimeInterval(TimeInterval(index))))
        }
        try await store.reconcileSkillOffers(
            candidateOfferKeys: keys,
            active: registrations)

        let review = try await store.proposedSkillOffers(limit: 3, at: now)
        XCTAssertEqual(
            review.map(\.lastObservedAt),
            [24, 23, 22].map { now.addingTimeInterval(TimeInterval($0)) })
        let plan = try await store.database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT offerKey, reviewID, skillID, skillVersion, reason,
                           proposedAt, lastObservedAt
                    FROM skillOfferProposal INDEXED BY skillOfferProposal_on_review
                    WHERE NOT EXISTS (
                        SELECT 1 FROM skillOfferDismissal
                        WHERE skillOfferDismissal.offerKey = skillOfferProposal.offerKey
                    )
                      AND NOT EXISTS (
                        SELECT 1 FROM skillDisablement
                        WHERE skillDisablement.skillID = skillOfferProposal.skillID
                    )
                    ORDER BY lastObservedAt DESC, offerKey ASC
                    LIMIT 20
                    """).map { $0["detail"] as String }
                .joined(separator: "\n")
        }
        XCTAssertTrue(plan.contains("skillOfferProposal_on_review"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)

        try await store.setSkill(RecapDraftSkill.id, isEnabled: false, at: now)
        let instant = now
        let disabledReview = try await LoadSkillOfferReview(
            store: store,
            now: { instant }).execute(LoadSkillOfferReviewRequest())
        XCTAssertTrue(disabledReview.offers.isEmpty)
        try await store.setSkill(RecapDraftSkill.id, isEnabled: true, at: now)
        try await store.setAllSkillsPaused(true, at: now)
        let pausedReview = try await LoadSkillOfferReview(
            store: store,
            now: { instant }).execute(LoadSkillOfferReviewRequest())
        XCTAssertTrue(pausedReview.offers.isEmpty)
    }
}

private actor RecordingSkillEffect: SkillEffectPerforming {
    private(set) var executionCount = 0

    func perform(_ proposal: SkillProposal) {
        executionCount += 1
    }
}
