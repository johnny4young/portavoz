import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

/// Q12/D316 — the proposal surface's durable rules, against the real store:
/// a dismissed offer never returns, a succeeded recap retires its offer, and
/// every confirmed run leaves exactly one auditable receipt for its meeting.
final class MeetingSkillOfferTests: XCTestCase {
    func testOffersRequireASummaryAndBothSkillsAppear() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()

        let without = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: false))
        XCTAssertTrue(without.isEmpty, "no summary, nothing to recap or export")

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(offers.map(\.kind), [.recapDraft, .packageExport])
    }

    func testDismissalIsDurableIdempotentAndPerOffer() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let recap = MeetingSkillOffer(kind: .recapDraft, meetingID: meetingID)

        try await store.dismissSkillOffer(
            offerKey: recap.offerKey,
            skillID: recap.skillID,
            at: Date(timeIntervalSince1970: 1))
        // Replay keeps the first dismissal instead of failing or rewriting.
        try await store.dismissSkillOffer(
            offerKey: recap.offerKey,
            skillID: recap.skillID,
            at: Date(timeIntervalSince1970: 2))

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(
            offers.map(\.kind), [.packageExport],
            "only the dismissed offer disappears")
    }

    /// The full confirmed loop against the real claims store: execute leaves a
    /// succeeded receipt, the recap offer retires, and export keeps offering
    /// because each destination is a distinct intended effect.
    func testASucceededRecapRetiresItsOfferAndLeavesOneReceipt() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let (proposal, key) = MeetingSkillProposalFactory.recapProposal(
            meetingID: meetingID,
            at: Date())

        let outcome = try await ExecuteSkill(
            claims: store,
            effects: [RecapDraftSkill.id: NoopSkillEffect()]
        ).execute(ExecuteSkillRequest(
            proposal: proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: key))
        guard case .performed = outcome else {
            return XCTFail("the confirmed recap must perform, saw \(outcome)")
        }

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(
            offers.map(\.kind), [.packageExport],
            "the draft exists; re-drafting is the manual sheet's job")

        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.map(\.skillID), [RecapDraftSkill.id])
        XCTAssertEqual(receipts.map(\.state), [.succeeded])
    }

    func testExportReceiptsBelongToTheirMeetingOnly() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let otherMeetingID = MeetingID()
        for (id, destination) in [
            (meetingID, "/tmp/a.portavoz"),
            (meetingID, "/tmp/b.portavoz"),
            (otherMeetingID, "/tmp/c.portavoz"),
        ] {
            let (proposal, key) = MeetingSkillProposalFactory
                .packageExportProposal(
                    meetingID: id,
                    destination: destination,
                    at: Date())
            _ = try await ExecuteSkill(
                claims: store,
                effects: [MeetingPackageExportSkill.id: NoopSkillEffect()]
            ).execute(ExecuteSkillRequest(
                proposal: proposal,
                isConfirmedByUser: true,
                egressIsPermitted: false,
                idempotencyKey: key))
        }

        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.count, 2, "the other meeting's run stays out")
        XCTAssertTrue(receipts.allSatisfy {
            $0.skillID == MeetingPackageExportSkill.id && $0.state == .succeeded
        })

        // Export keeps offering after success: a new destination is a new
        // intended effect.
        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertTrue(offers.contains { $0.kind == .packageExport })
    }

    /// A failed run keeps offering (retry is legitimate) and its receipt says
    /// so instead of disappearing.
    func testAFailedRecapKeepsOfferingAndReceiptsTheFailure() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let (proposal, key) = MeetingSkillProposalFactory.recapProposal(
            meetingID: meetingID,
            at: Date())

        let outcome = try await ExecuteSkill(
            claims: store,
            effects: [RecapDraftSkill.id: FailingSkillEffect()]
        ).execute(ExecuteSkillRequest(
            proposal: proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: key))
        guard case .failed = outcome else {
            return XCTFail("the failing effect must settle as failed")
        }

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertTrue(offers.contains { $0.kind == .recapDraft })
        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.map(\.state), [.failed])
    }

    func testProposalFactoryPinsArgumentsAndIdempotency() {
        let meetingID = MeetingID()
        let now = Date(timeIntervalSince1970: 500)

        let recap = MeetingSkillProposalFactory.recapProposal(
            meetingID: meetingID, at: now)
        XCTAssertEqual(recap.proposal.definition.id, RecapDraftSkill.id)
        XCTAssertEqual(recap.proposal.arguments, [.meeting(meetingID)])
        XCTAssertEqual(
            recap.idempotencyKey,
            RecapDraftSkill.idempotencyKey(for: meetingID))

        let export = MeetingSkillProposalFactory.packageExportProposal(
            meetingID: meetingID, destination: " /tmp/x.portavoz ", at: now)
        XCTAssertEqual(
            export.proposal.arguments,
            [.meeting(meetingID), .text(" /tmp/x.portavoz ")])
        XCTAssertEqual(
            export.idempotencyKey,
            MeetingPackageExportSkill.idempotencyKey(
                for: meetingID,
                destination: "/tmp/x.portavoz"),
            "the key normalizes exactly as the skill's own projection does")
    }

    /// The prefix read must treat LIKE metacharacters as literals: a key
    /// containing `%` or `_` (a destination path can) must not widen the scan.
    func testReceiptPrefixReadEscapesLikeMetacharacters() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let (proposal, key) = MeetingSkillProposalFactory
            .packageExportProposal(
                meetingID: meetingID,
                destination: "/tmp/100%_done.portavoz",
                at: Date())
        _ = try await ExecuteSkill(
            claims: store,
            effects: [MeetingPackageExportSkill.id: NoopSkillEffect()]
        ).execute(ExecuteSkillRequest(
            proposal: proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: key))

        let exact = try await store.skillExecutions(idempotencyKeyPrefix: key)
        XCTAssertEqual(exact.count, 1)
        let wildcard = try await store.skillExecutions(
            idempotencyKeyPrefix: "meeting-package-export:%")
        XCTAssertTrue(
            wildcard.isEmpty,
            "a literal % prefix must not act as a wildcard")
    }
}

private struct NoopSkillEffect: SkillEffectPerforming {
    func perform(_ proposal: SkillProposal) async throws {}
}

private struct FailingSkillEffect: SkillEffectPerforming {
    struct Failure: Error, CategorizedFailure {
        var category: FailureCategory { .degradable }
    }

    func perform(_ proposal: SkillProposal) async throws {
        throw Failure()
    }
}
