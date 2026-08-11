import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

/// Q12/D316 — the proposal surface's durable rules, against the real store:
/// a dismissed offer never returns, a succeeded one-shot draft retires, and
/// every confirmed run leaves exactly one auditable receipt for its meeting.
final class MeetingSkillOfferTests: XCTestCase {
    func testOffersRequireASummaryAndAllMeetingSkillsAppear() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()

        let without = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: false))
        XCTAssertTrue(without.isEmpty, "no summary, nothing to recap or export")

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(
            offers.map(\.kind),
            [.recapDraft, .emailRecapDraft, .packageExport])
    }

    func testOneShotOfferAndReceiptReadsStayBatchedAsAdaptersGrow() async throws {
        let store = RecordingMeetingSkillOfferStore()
        let meetingID = MeetingID()

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(
                meetingID: meetingID,
                hasSummary: true))
        XCTAssertEqual(
            offers.map(\.kind),
            [.recapDraft, .emailRecapDraft, .packageExport])
        var exactReads = await store.exactReads
        var prefixReads = await store.prefixReads
        XCTAssertEqual(exactReads, [[
            RecapDraftSkill.idempotencyKey(for: meetingID),
            EmailRecapDraftSkill.idempotencyKey(for: meetingID),
        ]])
        XCTAssertTrue(prefixReads.isEmpty)

        _ = try await LoadMeetingSkillReceipts(store: store).execute(meetingID)
        exactReads = await store.exactReads
        prefixReads = await store.prefixReads
        XCTAssertEqual(exactReads.count, 2)
        XCTAssertEqual(exactReads.last, [
            RecapDraftSkill.idempotencyKey(for: meetingID),
            EmailRecapDraftSkill.idempotencyKey(for: meetingID),
        ])
        XCTAssertEqual(prefixReads, [
            "\(MeetingPackageExportSkill.id):\(meetingID.rawValue.uuidString):",
        ])
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
            offers.map(\.kind), [.emailRecapDraft, .packageExport],
            "only the dismissed offer disappears")
    }

    func testDurableControlsRemoveOffersWithoutChangingDismissals() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()

        try await store.setSkill(
            RecapDraftSkill.id,
            isEnabled: false,
            at: Date())
        let oneEnabled = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(
            oneEnabled.map(\.kind),
            [.emailRecapDraft, .packageExport])

        try await store.setAllSkillsPaused(true, at: Date())
        let paused = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertTrue(paused.isEmpty)

        try await store.setAllSkillsPaused(false, at: Date())
        let resumed = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(meetingID: meetingID, hasSummary: true))
        XCTAssertEqual(
            resumed.map(\.kind),
            [.emailRecapDraft, .packageExport],
            "resuming must preserve the individual choice")
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
            policy: store,
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
            offers.map(\.kind), [.emailRecapDraft, .packageExport],
            "the draft exists; re-drafting is the manual sheet's job")

        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.map(\.skillID), [RecapDraftSkill.id])
        XCTAssertEqual(receipts.map(\.state), [.succeeded])
    }

    /// The email-app boundary needs two independent facts: the user confirmed
    /// the exact proposal and that confirmation permits this exact egress.
    /// Refusal happens before the durable claim or the effect.
    func testEmailRecapRequiresEgressPermissionThenRetiresAfterHandoff() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let (proposal, key) = MeetingSkillProposalFactory.emailRecapDraftProposal(
            meetingID: meetingID,
            at: Date())
        let effect = RecordingSkillEffect()
        let execute = ExecuteSkill(
            claims: store,
            policy: store,
            effects: [EmailRecapDraftSkill.id: effect])

        let refused = try await execute.execute(ExecuteSkillRequest(
            proposal: proposal,
            isConfirmedByUser: true,
            egressIsPermitted: false,
            idempotencyKey: key))
        XCTAssertEqual(refused, .refused(.egressNotPermitted))
        let refusedEffectProposalIDs = await effect.proposalIDs
        XCTAssertTrue(refusedEffectProposalIDs.isEmpty)
        let refusedExecutions = try await store.skillExecutions(
            idempotencyKeyPrefix: key)
        XCTAssertTrue(
            refusedExecutions.isEmpty,
            "a refused handoff must leave no durable may-have-acted receipt")

        let performed = try await execute.execute(ExecuteSkillRequest(
            proposal: proposal,
            isConfirmedByUser: true,
            egressIsPermitted: true,
            idempotencyKey: key))
        XCTAssertEqual(performed, .performed)
        let performedProposalIDs = await effect.proposalIDs
        XCTAssertEqual(performedProposalIDs, [proposal.id])

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(
                meetingID: meetingID,
                hasSummary: true))
        XCTAssertEqual(offers.map(\.kind), [.recapDraft, .packageExport])
        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.map(\.skillID), [EmailRecapDraftSkill.id])
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
                policy: store,
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
            policy: store,
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

    /// An executing record means the process may have crossed the handoff
    /// before it stopped. Re-offering either one-shot draft would invite a
    /// duplicate clipboard write or external composer with no safe evidence.
    func testInterruptedOneShotDraftsDoNotInviteDuplicateHandoffs() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let proposals = [
            MeetingSkillProposalFactory.recapProposal(
                meetingID: meetingID,
                at: Date(timeIntervalSince1970: 100)),
            MeetingSkillProposalFactory.emailRecapDraftProposal(
                meetingID: meetingID,
                at: Date(timeIntervalSince1970: 101)),
        ]
        for item in proposals {
            _ = try await store.confirmSkillExecution(
                proposalID: item.proposal.id,
                skillID: item.proposal.definition.id,
                skillVersion: item.proposal.definition.version,
                idempotencyKey: item.idempotencyKey,
                at: item.proposal.proposedAt)
            _ = try await store.beginSkillExecution(
                proposalID: item.proposal.id,
                at: item.proposal.proposedAt)
        }

        let offers = try await LoadMeetingSkillOffers(store: store).execute(
            LoadMeetingSkillOffersRequest(
                meetingID: meetingID,
                hasSummary: true))
        XCTAssertEqual(offers.map(\.kind), [.packageExport])

        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(Set(receipts.map(\.skillID)), [
            EmailRecapDraftSkill.id,
            RecapDraftSkill.id,
        ])
        XCTAssertTrue(receipts.allSatisfy { $0.state == .executing })
    }

    /// Storage spells a pre-handoff cancellation `cancelled`; the domain
    /// projects that as the terminal no-effect state `dismissed`. Receipts
    /// must keep it visible instead of dropping an unknown raw value.
    func testCancelledConfirmationRemainsVisibleAsADismissedReceipt() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID()
        let (proposal, key) = MeetingSkillProposalFactory.recapProposal(
            meetingID: meetingID,
            at: Date(timeIntervalSince1970: 100))

        _ = try await store.confirmSkillExecution(
            proposalID: proposal.id,
            skillID: proposal.definition.id,
            skillVersion: proposal.definition.version,
            idempotencyKey: key,
            at: Date(timeIntervalSince1970: 100))
        _ = try await store.cancelSkillExecution(
            proposalID: proposal.id,
            at: Date(timeIntervalSince1970: 101))

        let receipts = try await LoadMeetingSkillReceipts(store: store)
            .execute(meetingID)
        XCTAssertEqual(receipts.map(\.state), [.dismissed])
    }

    func testProposalFactoryPinsArgumentsAndIdempotency() {
        let meetingID = MeetingID()
        let recapProposalID = UUID()
        let emailProposalID = UUID()
        let exportProposalID = UUID()
        let now = Date(timeIntervalSince1970: 500)

        let recap = MeetingSkillProposalFactory.recapProposal(
            proposalID: recapProposalID,
            meetingID: meetingID, at: now)
        XCTAssertEqual(recap.proposal.id, recapProposalID)
        XCTAssertEqual(recap.proposal.proposedAt, now)
        XCTAssertEqual(recap.proposal.definition.id, RecapDraftSkill.id)
        XCTAssertEqual(recap.proposal.arguments, [.meeting(meetingID)])
        XCTAssertEqual(
            recap.idempotencyKey,
            RecapDraftSkill.idempotencyKey(for: meetingID))

        let email = MeetingSkillProposalFactory.emailRecapDraftProposal(
            proposalID: emailProposalID,
            meetingID: meetingID,
            at: now)
        XCTAssertEqual(email.proposal.id, emailProposalID)
        XCTAssertEqual(email.proposal.proposedAt, now)
        XCTAssertEqual(
            email.proposal.definition,
            EmailRecapDraftSkill.definition)
        XCTAssertEqual(
            email.proposal.requestedCapabilities,
            [.readMeetingMaterial, .sendRemote])
        XCTAssertEqual(email.proposal.arguments, [.meeting(meetingID)])
        XCTAssertEqual(
            email.idempotencyKey,
            EmailRecapDraftSkill.idempotencyKey(for: meetingID))

        let export = MeetingSkillProposalFactory.packageExportProposal(
            proposalID: exportProposalID,
            meetingID: meetingID, destination: " /tmp/x.portavoz ", at: now)
        XCTAssertEqual(export.proposal.id, exportProposalID)
        XCTAssertEqual(export.proposal.proposedAt, now)
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
            policy: store,
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

private actor RecordingSkillEffect: SkillEffectPerforming {
    private(set) var proposalIDs: [UUID] = []

    func perform(_ proposal: SkillProposal) {
        proposalIDs.append(proposal.id)
    }
}

private struct FailingSkillEffect: SkillEffectPerforming {
    struct Failure: Error, CategorizedFailure {
        var category: FailureCategory { .degradable }
    }

    func perform(_ proposal: SkillProposal) async throws {
        throw Failure()
    }
}

private actor RecordingMeetingSkillOfferStore: MeetingSkillOfferStore {
    private(set) var exactReads: [[String]] = []
    private(set) var prefixReads: [String] = []

    func skillExecutionPolicy() -> SkillExecutionPolicy {
        SkillExecutionPolicy()
    }

    func dismissedSkillOffers(offerKeys: [String]) -> Set<String> { [] }

    func skillExecutions(
        idempotencyKeys: [String]
    ) -> [SkillExecutionRecord] {
        exactReads.append(idempotencyKeys)
        return []
    }

    func skillExecutions(
        idempotencyKeyPrefix prefix: String
    ) -> [SkillExecutionRecord] {
        prefixReads.append(prefix)
        return []
    }

    func dismissSkillOffer(
        offerKey: String,
        skillID: String,
        at timestamp: Date
    ) {}
}
