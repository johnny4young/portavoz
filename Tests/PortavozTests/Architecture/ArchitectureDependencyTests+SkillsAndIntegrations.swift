import ApplicationKit
import Foundation
import XCTest

@testable import portavoz_app

extension ArchitectureDependencyTests {
    func testSkillExecutionAdmitsBeforeItClaimsAndKeepsPlatformOut() throws {
        let policy = try Self.contents(of: "Sources/PortavozCore/Skill.swift")
        let executor = try Self.contents(
            of: "Sources/ApplicationKit/ExecuteSkill.swift")
        let skill = try Self.contents(
            of: "Sources/ApplicationKit/ReminderDraftSkill.swift")
        let executionStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecution.swift")
        let standingExecutionStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+StandingSkillExecution.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // Admission is decided from the declaration alone, so the policy never
        // reaches for storage or a model.
        for forbidden in ["import StorageKit", "import Foundation\nimport GRDB"] {
            XCTAssertFalse(policy.contains(forbidden), forbidden)
        }
        XCTAssertTrue(policy.contains("isSubset(of: proposal.definition.capabilities)"))
        XCTAssertTrue(policy.contains("public static let confirmationValidity"))

        // Refusal must precede the durable claim: a refused proposal that
        // wrote a claim would be an execution nobody can settle.
        let policyIndex = try XCTUnwrap(
            executor.range(of: "policy.skillExecutionPolicy")?.lowerBound)
        let admitIndex = try XCTUnwrap(
            executor.range(of: "SkillAdmissionPolicy.admit")?.lowerBound)
        let claimIndex = try XCTUnwrap(
            executor.range(
                of: "if let outcome = try await confirmationOutcome(")?.lowerBound)
        XCTAssertLessThan(policyIndex, admitIndex)
        XCTAssertLessThan(admitIndex, claimIndex)
        let effectIndex = try XCTUnwrap(
            executor.range(of: "effect.perform(proposal)")?.lowerBound)
        XCTAssertLessThan(claimIndex, effectIndex)
        XCTAssertTrue(executor.contains("claims.confirmSkillExecution"))

        // One authority for which states may proceed.
        XCTAssertTrue(executor.contains("case .admitted, .alreadySettled:"))
        XCTAssertFalse(executor.contains("record.state == .confirmed"))

        // Storage transitions carry one typed event/state/category command,
        // so a parameter list cannot cross-wire a terminal event and state.
        XCTAssertTrue(executionStore.contains("struct SkillExecutionEventWrite"))
        XCTAssertTrue(executionStore.contains("struct SkillExecutionTransition"))
        XCTAssertFalse(executionStore.contains(
            "public struct SkillExecutionTransition"))
        XCTAssertTrue(executionStore.contains("case failed(FailureCategory)"))
        XCTAssertTrue(executionStore.contains("transition.event(previousEventID: previous)"))
        XCTAssertFalse(executionStore.contains("kind: String,\n        state: String,"))
        XCTAssertTrue(standingExecutionStore.contains(
            "SkillExecutionTransition("))
        XCTAssertFalse(standingExecutionStore.contains(
            "kind: String,\n        state: String,"))

        // Platform effects stay behind ports.
        for forbidden in ["import EventKit", "import SwiftUI", "import AppKit"] {
            XCTAssertFalse(executor.contains(forbidden), forbidden)
            XCTAssertFalse(skill.contains(forbidden), forbidden)
        }
        XCTAssertTrue(skill.contains("public protocol ReminderDraftDelivering"))
        XCTAssertTrue(decisions.contains("## D292"))
        XCTAssertTrue(decisions.contains("## D293"))
        XCTAssertTrue(decisions.contains("## D294"))
    }

    func testSkillsControlCenterSharesDurableFailClosedAuthority() throws {
        let skill = try Self.contents(
            of: "Sources/PortavozCore/Skill.swift")
        let control = try Self.contents(
            of: "Sources/ApplicationKit/SkillsControlCenter.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillControl.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SkillControl.swift")
        let executionReviewSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+SkillExecutionReview.swift")
        let executionFilterSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+SkillExecutionReviewFilter.swift")
        let offers = try Self.contents(
            of: "Sources/ApplicationKit/MeetingSkillOffers.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SkillsSettingsSection.swift")
        let activity = try Self.contents(
            of: "Sources/portavoz-app/SkillActivitySection.swift")
        let activityPeriod = try Self.contents(
            of: "Sources/portavoz-app/SkillActivityPeriodFilter.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillsControl.swift")
        let featureHandshake = try Self.contents(
            of: "Sources/portavoz-app/UITestFeatureHandshake.swift")
        let uiFixtures = try Self.contents(
            of: "Sources/portavoz-app/AppServices+UITestFixtures.swift")
        let receiptInspection = try Self.contents(
            of: "Sources/ApplicationKit/SkillReceiptInspection.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let executionStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecution.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(control.contains("enum SkillCatalogue"))
        XCTAssertFalse(control.contains("availability: .planned"))
        XCTAssertTrue(control.contains("defaultReceiptLimit = 20"))
        XCTAssertTrue(control.contains("maximumReceiptLimit = 50"))
        XCTAssertTrue(store.contains("maximumRecentSkillExecutionCount = 100"))
        XCTAssertTrue(store.contains("ORDER BY updatedAt DESC, proposalID ASC"))
        XCTAssertTrue(schema.contains("CREATE INDEX skillExecutionState_on_recent"))
        XCTAssertTrue(schema.contains("updatedAt DESC, proposalID ASC"))
        XCTAssertTrue(skill.contains("enum SkillExecutionReviewScope"))
        XCTAssertTrue(skill.contains("case needsAttention = \"needs-attention\""))
        XCTAssertTrue(skill.contains("enum SkillExecutionReviewPeriod"))
        XCTAssertTrue(skill.contains("case pastMonth = \"past-month\""))
        XCTAssertTrue(control.contains("receiptScope: SkillExecutionReviewScope"))
        XCTAssertTrue(control.contains(
            "receiptPeriod: SkillExecutionReviewPeriod"))
        XCTAssertTrue(control.contains(
            "receiptReferenceDate: Date = .now"))
        XCTAssertTrue(control.contains(
            "let receiptUpdatedAfter = try Self.receiptUpdatedAfter(for: request)"))
        XCTAssertTrue(control.contains(
            "updatedAfter: receiptUpdatedAfter"))
        XCTAssertTrue(control.contains("scope: request.receiptScope"))
        XCTAssertTrue(control.contains(
            "let receiptProbeLimit = request.receiptLimit + 1"))
        XCTAssertTrue(control.contains(
            "resolvedRecords.prefix(request.receiptLimit)"))
        XCTAssertTrue(control.contains("hasMoreReceipts:"))
        XCTAssertTrue(store.contains("FROM skillExecutionState INDEXED BY"))
        XCTAssertTrue(store.contains("updatedAt >= ?"))
        XCTAssertTrue(store.contains("skillExecutionState_on_waiting"))
        XCTAssertTrue(store.contains("skillExecutionState_on_attention"))
        XCTAssertTrue(store.contains("skillExecutionState_on_completed"))
        XCTAssertTrue(executionReviewSchema.contains(
            "WHERE state = 'confirmed'"))
        XCTAssertTrue(executionReviewSchema.contains(
            "WHERE state NOT IN ('confirmed', 'succeeded', 'cancelled')"))
        XCTAssertTrue(executionReviewSchema.contains(
            "WHERE state IN ('succeeded', 'cancelled')"))
        XCTAssertTrue(executionFilterSchema.contains(
            "registerMigration(\"v42\")"))
        XCTAssertTrue(executionFilterSchema.contains(
            "skillExecutionState_on_recent_skill"))
        XCTAssertTrue(executionFilterSchema.contains(
            "skillID, updatedAt DESC, proposalID ASC"))
        XCTAssertTrue(offers.contains("store.skillExecutionPolicy()"))
        XCTAssertTrue(offers.contains(
            "store.skillExecutions(\n            idempotencyKeys: oneShotKeys)"))
        XCTAssertTrue(settings.contains("settings-skills-pause-all"))
        XCTAssertTrue(settings.contains("settings-skill-\\(skill.id)-enabled"))
        XCTAssertTrue(settings.contains(
            "Button(\"Reload controls\") {\n"
                + "                        Task { await load() }\n"
                + "                    }\n"
                + "                    .accessibilityIdentifier("
                + "\"settings-skills-stale-retry\")"))
        XCTAssertFalse(settings.contains("Close and reopen Settings"))
        XCTAssertTrue(activity.contains("settings-skills-receipt-scope-recent"))
        XCTAssertTrue(activity.contains("settings-skills-receipt-scope-waiting"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-scope-needs-attention"))
        XCTAssertTrue(activity.contains("settings-skills-receipt-scope-completed"))
        XCTAssertTrue(activity.contains("enum SkillActivityPresentationState"))
        XCTAssertTrue(activity.contains("struct SkillActivityHistoryWindow"))
        XCTAssertTrue(activity.contains(
            "requestedLimit =\n        SkillControlCenterSnapshot.defaultReceiptLimit"))
        XCTAssertTrue(activity.contains(
            "requestedLimit = SkillControlCenterSnapshot.maximumReceiptLimit"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-show-more"))
        XCTAssertTrue(activity.contains(
            "hasMoreReceipts: snapshot?.hasMoreReceipts ?? false"))
        XCTAssertTrue(settings.contains(
            "hasMoreReceipts: snapshot.hasMoreReceipts"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-skill-filter"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-skill-\\(skill.id)"))
        XCTAssertTrue(activity.contains(
            "snapshot.receiptSkillID == receiptSkillID"))
        XCTAssertTrue(activity.contains(
            "snapshot.receiptPeriod == receiptPeriod"))
        XCTAssertTrue(activityPeriod.contains(
            "settings-skills-receipt-period-filter"))
        XCTAssertTrue(activityPeriod.contains(
            "settings-skills-receipt-period-\\(identifier)"))
        XCTAssertTrue(activityPeriod.contains(
            ".accessibilityLabel(\"Filter activity by update time\")"))
        XCTAssertTrue(activity.contains(
            "if presentationState.allowsExplicitRefresh"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-refresh"))
        XCTAssertTrue(activity.contains(
            "func allowsFilterReset(hasActiveFilters: Bool) -> Bool"))
        XCTAssertTrue(activity.contains(
            "settings-skills-receipt-clear-filters"))
        XCTAssertTrue(settings.contains(
            "clearFilters: clearActivityFilters"))
        XCTAssertFalse(activity.contains("Timer"))
        XCTAssertTrue(activity.contains("if isLoading"))
        XCTAssertTrue(activity.contains(
            "snapshot.receiptLoadState == .verified"))
        XCTAssertTrue(settings.contains(".task(id: activitySelection)"))
        XCTAssertTrue(settings.contains(
            "receiptHistoryWindow.reset()\n            await load()"))
        XCTAssertTrue(settings.contains(
            "receiptLimit: requestedLimit"))
        XCTAssertTrue(settings.contains(
            "receiptSkillID: requestedSkillID"))
        XCTAssertTrue(settings.contains(
            "receiptPeriod: requestedPeriod"))
        XCTAssertTrue(settings.contains(
            "receiptSkillID == requestedSkillID"))
        XCTAssertTrue(settings.contains(
            "receiptPeriod == requestedPeriod"))
        XCTAssertTrue(settings.contains(
            "receiptHistoryWindow.requestedLimit == requestedLimit"))
        XCTAssertTrue(decisions.contains("## D373"))
        XCTAssertTrue(settings.contains(
            "receiptHistoryWindow.expand()\n        await load()"))
        XCTAssertTrue(settings.contains(
            "refresh: { Task { await refreshActivity() } }"))
        let refreshActivityContract = [
            "private func refreshActivity() async {",
            "        guard let snapshot,",
            "              snapshot.receiptScope == receiptScope,",
            "              snapshot.receiptSkillID == receiptSkillID,",
            "              snapshot.receiptPeriod == receiptPeriod,",
            "              snapshot.receiptLoadState == .verified,",
            "              !isLoading,",
            "              !isMutating,",
            "              !auxiliaryMutationInFlight",
            "        else { return }",
            "        await load()",
            "    }"
        ].joined(separator: "\n")
        XCTAssertTrue(settings.contains(refreshActivityContract))
        let clearActivityFiltersContract = [
            "private func clearActivityFilters() {",
            "        guard let snapshot,",
            "              snapshot.receiptScope == receiptScope,",
            "              snapshot.receiptSkillID == receiptSkillID,",
            "              snapshot.receiptPeriod == receiptPeriod,",
            "              snapshot.receiptLoadState == .verified,",
            "              snapshot.receipts.isEmpty,",
            "              receiptSkillID != nil || receiptPeriod != .anytime,",
            "              !isLoading,",
            "              !isMutating,",
            "              !auxiliaryMutationInFlight",
            "        else { return }",
            "        receiptSkillID = nil",
            "        receiptPeriod = .anytime",
            "    }"
        ].joined(separator: "\n")
        XCTAssertTrue(settings.contains(clearActivityFiltersContract))
        XCTAssertTrue(decisions.contains("## D376"))
        XCTAssertTrue(settings.contains("invalidateActiveLoad()"))
        XCTAssertTrue(control.contains(
            "enum SkillControlCenterReceiptLoadState"))
        XCTAssertTrue(control.contains("receiptLoadState = .unavailable"))
        XCTAssertTrue(services.contains("usesTemporaryMeetingStore"))
        XCTAssertTrue(services.contains(
            "-simulate-skill-receipt-refresh-handshake"))
        XCTAssertFalse(services.contains("Task.sleep(for: .seconds(4))"))
        XCTAssertTrue(featureHandshake.contains("attempts: Int = 600"))
        XCTAssertTrue(featureHandshake.contains("guard attempts > 0"))
        XCTAssertTrue(featureHandshake.contains("try Task.checkCancellation()"))
        XCTAssertTrue(featureHandshake.contains(
            ".hasPrefix(\"portavoz-uitest-\")"))
        XCTAssertTrue(featureHandshake.contains(
            "let signalDirectory = signalURL.deletingLastPathComponent()"))
        XCTAssertTrue(featureHandshake.contains(
            "let processTemporaryPath = environment[\"TMPDIR\"]"))
        XCTAssertTrue(featureHandshake.contains(
            "signalDirectory == processTemporaryDirectory"))
        XCTAssertFalse(featureHandshake.contains(
            "FileManager.default.temporaryDirectory"))
        XCTAssertTrue(featureHandshake.contains("throw TimedOut()"))
        XCTAssertTrue(services.contains(
            "if usesTemporaryMeetingStore,\n"
                + "           ProcessInfo.processInfo.arguments.contains(\n"
                + "               \"-simulate-skill-control-mutation-unavailable\")"))
        let controlMutation = try XCTUnwrap(services.range(
            of: "let outcome = try await ManageSkillControl(store: store)"))
        let simulatedResponseFailure = try XCTUnwrap(services.range(
            of: "-simulate-skill-control-mutation-unavailable"))
        XCTAssertLessThan(
            controlMutation.lowerBound,
            simulatedResponseFailure.lowerBound)
        XCTAssertTrue(services.contains(
            "if usesTemporaryMeetingStore,\n"
                + "           ProcessInfo.processInfo.arguments.contains(\n"
                + "               \"-simulate-skill-proposal-unavailable\")"))
        XCTAssertTrue(uiFixtures.contains(
            "-seed-skill-exact-page-history"))
        XCTAssertTrue(uiFixtures.contains(
            "? SkillControlCenterSnapshot.defaultReceiptLimit\n"
                + "            : 25"))
        XCTAssertTrue(uiFixtures.contains("for ordinal in 1...receiptCount"))
        XCTAssertTrue(uiFixtures.contains(
            "-seed-skill-recent-history"))
        XCTAssertTrue(uiFixtures.contains(
            "let offerKey = \"\\(MeetingPackageExportSkill.id):\""))
        XCTAssertTrue(uiFixtures.contains(
            "idempotencyKey: effectKey"))
        XCTAssertTrue(activity.contains(
            "notification: .announcementRequested"))
        XCTAssertTrue(control.contains("definition.declaresExternalEffect"))
        XCTAssertTrue(control.contains("enum SkillDisclosureBoundary"))
        XCTAssertTrue(settings.contains("skill.disclosureBoundary"))
        XCTAssertTrue(settings.contains(
            "skill.definition.confirmationPolicy == .explicitPerProposal"))
        XCTAssertFalse(settings.contains("Label(\"On this Mac\""))
        XCTAssertFalse(settings.contains("UserDefaults"))
        XCTAssertTrue(executionStore.contains("public func skillExecutionAudit("))
        XCTAssertTrue(executionStore.contains(
            "maximumSkillExecutionAuditEventCount = 256"))
        XCTAssertTrue(executionStore.contains(
            "let history = try Self.skillExecutionHistory("))
        XCTAssertTrue(executionStore.contains(
            "limit: Self.maximumSkillExecutionAuditEventCount + 1"))
        XCTAssertTrue(executionStore.contains(
            "previousEventID == latestEventID"))
        XCTAssertTrue(executionStore.contains(
            "history.latestEventID == projectedLatestEventID"))
        XCTAssertTrue(receiptInspection.contains("validateAndProject(audit)"))
        XCTAssertTrue(receiptInspection.contains("case inconsistentHistory"))
        XCTAssertFalse(receiptInspection.contains(".idempotencyKey"))
        XCTAssertTrue(receiptSheet.contains("skill-receipt-inspection-privacy"))
        XCTAssertTrue(receiptSheet.contains(
            "never runs or retries an action"))
        XCTAssertTrue(decisions.contains("## D317"))
        XCTAssertTrue(decisions.contains("## D333"))
        XCTAssertTrue(decisions.contains("## D370"))
        XCTAssertTrue(decisions.contains("## D371"))
        XCTAssertTrue(decisions.contains("## D372"))
        XCTAssertTrue(decisions.contains("## D374"))
        XCTAssertTrue(decisions.contains("## D375"))
        XCTAssertTrue(decisions.contains("## D335"))
        XCTAssertTrue(decisions.contains("## D336"))
        XCTAssertTrue(decisions.contains("## D343"))
    }

    func testWaitingSkillRevocationKeepsContentAndEffectAuthorityOutOfSettings() throws {
        let revocation = try Self.contents(
            of: "Sources/ApplicationKit/RevokeWaitingSkillExecution.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillsControl.swift")
        let fixtures = try Self.contents(
            of: "Sources/portavoz-app/AppServices+UITestFixtures.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(revocation.contains(
            "protocol WaitingSkillExecutionRevoking: Sendable"))
        XCTAssertTrue(revocation.contains("func cancelSkillExecution("))
        XCTAssertFalse(revocation.contains("idempotencyKey:"))
        XCTAssertFalse(revocation.contains("effect.perform"))
        XCTAssertFalse(revocation.contains("SkillProposal"))
        XCTAssertTrue(receiptSheet.contains(
            "if inspection?.state == .confirmed"))
        XCTAssertTrue(receiptSheet.contains(
            "guard inspection?.state == .confirmed,"))
        XCTAssertTrue(receiptSheet.contains("!isRevoking"))
        XCTAssertTrue(receiptSheet.contains(
            "await reloadAfterVerifiedMutation()"))
        XCTAssertTrue(receiptSheet.contains("skill-receipt-revoke-action"))
        XCTAssertFalse(receiptSheet.contains(".idempotencyKey"))
        XCTAssertTrue(services.contains("usesTemporaryMeetingStore"))
        XCTAssertTrue(services.contains(
            "-simulate-skill-receipt-revoke-unavailable"))
        XCTAssertTrue(fixtures.contains("guard usesTemporaryMeetingStore"))
        XCTAssertTrue(fixtures.contains("-seed-skill-waiting"))
        XCTAssertTrue(decisions.contains("## D339"))
    }

    func testSkillProposalReviewHasContentFreeBoundedAuthority() throws {
        let skill = try Self.contents(of: "Sources/PortavozCore/Skill.swift")
        let authority = try Self.contents(
            of: "Sources/PortavozCore/SkillOfferAuthority.swift")
        let review = try Self.contents(
            of: "Sources/ApplicationKit/SkillOfferReview.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillOfferAuthority.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SkillOfferAuthority.swift")
        let execution = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecution.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SkillsSettingsSection.swift")
        let proposalSection = try Self.contents(
            of: "Sources/portavoz-app/SkillProposalSection.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillsControl.swift")
        let fixtures = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillProposalUITestFixtures.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/SkillsSettingsUITests.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(skill.contains("enum SkillInputDataClass"))
        XCTAssertTrue(skill.contains("requestedInputDataClasses"))
        XCTAssertTrue(skill.contains("isSubset(of: proposal.definition.inputDataClasses)"))
        XCTAssertTrue(authority.contains("maximumOfferKeyByteCount = 2_200"))
        XCTAssertTrue(authority.contains("public let reason: SkillOfferReason"))
        XCTAssertTrue(authority.contains("public let id: UUID"))
        XCTAssertFalse(authority.contains("public let title:"))
        XCTAssertFalse(authority.contains("public let transcript:"))
        XCTAssertTrue(store.contains("maximumSkillOfferReconciliationCount = 200"))
        XCTAssertTrue(store.contains("maximumSkillOfferReviewCount = 100"))
        XCTAssertTrue(store.contains("INDEXED BY skillOfferProposal_on_review"))
        XCTAssertTrue(store.contains("ORDER BY lastObservedAt DESC, offerKey ASC"))
        XCTAssertTrue(schema.contains("registerMigration(\"v40\")"))
        XCTAssertTrue(schema.contains("skillOfferProposalInput"))
        XCTAssertTrue(schema.contains("ON skillOfferProposal(lastObservedAt DESC, offerKey ASC)"))
        XCTAssertTrue(review.contains("maximumLimit = 50"))
        XCTAssertTrue(review.contains("catalogue.definition.version == record.skillVersion"))
        XCTAssertFalse(review.contains("let offerKey:"))
        XCTAssertFalse(review.contains("let subject:"))
        XCTAssertTrue(review.contains("struct DismissSkillOfferReview"))
        XCTAssertTrue(authority.contains(
            "enum SkillOfferReviewDismissalOutcome"))
        XCTAssertTrue(store.contains("dismissProposedSkillOffer("))
        XCTAssertTrue(store.contains("let dismissed = activeKeys.isEmpty"))
        XCTAssertTrue(store.contains(
            "for offer in offers where !dismissed.contains(offer.offerKey)"))
        XCTAssertTrue(execution.contains("case offerDismissed"))
        XCTAssertTrue(execution.contains(
            "SELECT 1 FROM skillOfferDismissal WHERE offerKey = ?"))
        XCTAssertTrue(execution.contains(
            "confirmation.idempotencyKey.hasPrefix("))
        XCTAssertTrue(execution.contains(
            "confirmation.offerKey + \":\""))
        XCTAssertTrue(execution.contains(
            "DELETE FROM skillOfferProposal WHERE offerKey = ?"))
        XCTAssertTrue(settings.contains("activeProposalLoadID == loadID"))
        XCTAssertTrue(settings.contains(
            "services.dismissSkillOfferReview(offer.id)"))
        XCTAssertTrue(proposalSection.contains("settings-skills-proposals-privacy"))
        XCTAssertTrue(proposalSection.contains(
            "settings-skill-proposal-dismiss-"))
        XCTAssertTrue(proposalSection.contains(
            "enum SkillProposalPresentationState"))
        XCTAssertTrue(proposalSection.contains(
            "if presentationState.allowsExplicitRefresh"))
        XCTAssertTrue(proposalSection.contains(
            "settings-skills-proposals-refreshing"))
        XCTAssertTrue(proposalSection.contains(
            "settings-skills-proposals-refresh"))
        XCTAssertTrue(proposalSection.contains(
            "struct SkillProposalAccessibilityPosition"))
        XCTAssertTrue(proposalSection.contains(
            "ForEach(Array(offers.enumerated()), id: \\.element.id)"))
        XCTAssertTrue(proposalSection.contains(
            "Proposal %d of %d"))
        XCTAssertTrue(proposalSection.contains("Nothing runs here."))
        XCTAssertFalse(proposalSection.contains("offer.offerKey"))
        XCTAssertFalse(proposalSection.contains("offer.subject"))
        XCTAssertFalse(proposalSection.contains("offer.title"))
        XCTAssertFalse(proposalSection.contains("offer.transcript"))
        XCTAssertFalse(proposalSection.contains("Timer"))
        XCTAssertTrue(settings.contains(
            "refresh: { Task { await refreshProposals() } }"))
        let refreshProposalsContract = [
            "func refreshProposals() async {",
            "        guard proposalSnapshot != nil,",
            "              !proposalLoadFailed,",
            "              !proposalsAreLoading,",
            "              !isMutating,",
            "              !auxiliaryMutationInFlight",
            "        else { return }",
            "        await loadProposals()",
            "    }"
        ].joined(separator: "\n")
        XCTAssertTrue(settings.contains(refreshProposalsContract))
        XCTAssertTrue(services.contains(
            "-simulate-skill-proposal-refresh-handshake"))
        XCTAssertTrue(fixtures.contains("guard usesTemporaryMeetingStore"))
        XCTAssertTrue(fixtures.contains(
            "-seed-duplicate-skill-proposals"))
        XCTAssertTrue(fixtures.contains("LoadMeetingSkillOffers("))
        XCTAssertTrue(uiTest.contains(
            "testSameSkillProposalsHaveDistinctAccessibleActions"))
        XCTAssertTrue(uiTest.contains(
            "component: \"review\""))
        XCTAssertTrue(uiTest.contains(
            "component: \"dismiss\""))
        XCTAssertTrue(uiTest.contains(
            "settings-skill-proposal-\\(component)-action-email-recap-draft-"))
        XCTAssertTrue(uiTest.contains(
            "settings-skill-proposal-email-recap-draft-"))

        for producer in [
            "Sources/ApplicationKit/MeetingSkillOffers.swift",
            "Sources/ApplicationKit/PreMeetingBriefOffers.swift",
            "Sources/ApplicationKit/ReminderDraftOffers.swift",
        ] {
            XCTAssertTrue(
                try Self.contents(of: producer).contains("reconcileSkillOffers("),
                "proposal producer is outside the central authority: \(producer)")
        }
        XCTAssertTrue(decisions.contains("## D337"))
        XCTAssertTrue(decisions.contains("## D338"))
        XCTAssertTrue(decisions.contains("## D377"))
        XCTAssertTrue(decisions.contains("## D378"))
    }

    func testSuggestedActionsVocabularyKeepsInternalSkillContractsStable() throws {
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SkillsSettingsSection.swift")
        let proposals = try Self.contents(
            of: "Sources/portavoz-app/SkillProposalSection.swift")
        let activity = try Self.contents(
            of: "Sources/portavoz-app/SkillActivitySection.swift")
        let offerBanner = try Self.contents(
            of: "Sources/portavoz-app/SkillOfferBanner.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let receiptPresentation = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptPresentation.swift")
        let catalogue = try Self.contents(
            of: "Resources/Localization/Portavoz/Localizable.xcstrings")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/SkillsSettingsUITests.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let product = try Self.contents(of: "docs/PRODUCT.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")

        XCTAssertEqual(SettingsCategory.skills.rawValue, "skills")
        XCTAssertEqual(SettingsCategory.skills.titleKey, "Suggested actions")
        for query in ["actions", "suggestions", "skills", "automation", "pause", "enable", "receipts"] {
            XCTAssertTrue(SettingsCategory.skills.matches(query, language: .english), query)
        }

        XCTAssertTrue(settings.contains("Section(\"Available actions\")"))
        XCTAssertTrue(settings.contains("Section(\"Suggestions to review\")"))
        XCTAssertTrue(settings.contains("Section(\"Action history\")"))
        XCTAssertTrue(settings.contains(
            "Portavoz suggests actions based on evidence from your meetings."))
        XCTAssertTrue(settings.contains(
            "Nothing runs until you review and confirm it."))
        XCTAssertTrue(settings.contains("settings-actions-explanation"))
        XCTAssertTrue(settings.contains(
            ".accessibilityLabel(\"Pause all actions\")"))
        XCTAssertTrue(settings.contains("settings-skills-pause-all"))
        XCTAssertFalse(settings.contains("Section(\"Skill suggestions\")"))
        XCTAssertFalse(settings.contains("Section(\"Skill activity\")"))

        XCTAssertTrue(proposals.contains("Loading suggested actions…"))
        XCTAssertTrue(proposals.contains("Suggested actions are unavailable"))
        XCTAssertTrue(proposals.contains("No suggested actions"))
        XCTAssertTrue(proposals.contains("Refresh suggested actions"))
        XCTAssertTrue(activity.contains("Text(\"Action\")"))
        XCTAssertTrue(activity.contains("Button(\"All actions\")"))
        XCTAssertTrue(activity.contains("Filter history by action"))
        XCTAssertFalse(activity.contains("Button(\"All skills\")"))
        XCTAssertFalse(activity.contains("Text(\"Skill\")"))
        XCTAssertTrue(offerBanner.contains(
            ".accessibilityLabel(L10n.text(\"Suggested actions\"))"))
        XCTAssertTrue(receiptSheet.contains("change the action run"))
        XCTAssertFalse(receiptSheet.contains("change the Skill run"))
        XCTAssertTrue(receiptPresentation.contains("Unknown action"))

        XCTAssertTrue(catalogue.contains("\"Suggested actions\""))
        XCTAssertTrue(catalogue.contains("\"Acciones sugeridas\""))
        XCTAssertTrue(catalogue.contains("\"Pausar todas las acciones\""))
        XCTAssertTrue(catalogue.contains(
            "Nada se ejecuta hasta que revisas y confirmas cada acción."))
        XCTAssertTrue(uiTest.contains("assertSuggestedActionsComprehension"))
        XCTAssertTrue(uiTest.contains(
            "testSuggestedActionsExplainReviewFirstSafety"))
        XCTAssertTrue(uiTest.contains("settings-category-skills"))
        XCTAssertTrue(uiTest.contains("settings-actions-explanation"))
        XCTAssertTrue(uiTest.contains("Pause all actions"))

        XCTAssertTrue(decisions.contains("## D379"))
        XCTAssertTrue(gaps.contains("SEVEN-ACTION BASELINE IN CODE"))
        XCTAssertTrue(gaps.contains("Portavoz 1.0.0 candidate scope and exit gates"))
        XCTAssertTrue(product.contains("### 1.0.0 candidate boundary"))
        XCTAssertTrue(appSpec.contains(
            "## Suggested-actions control center in Settings"))
        XCTAssertTrue(appSpec.contains(
            "Twenty bilingual XCUITest journeys cover the pane"))
    }

    func testSkillProposalReviewRoutingIsOpaqueInertAndValueScoped() throws {
        let authority = try Self.contents(
            of: "Sources/PortavozCore/SkillOfferAuthority.swift")
        let review = try Self.contents(
            of: "Sources/ApplicationKit/SkillOfferReview.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillOfferAuthority.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillsControl.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SkillsSettingsSection.swift")
        let proposal = try Self.contents(
            of: "Sources/portavoz-app/SkillProposalSection.swift")
        let app = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")
        let mainIdentity = try Self.contents(
            of: "Sources/portavoz-app/MainWindowIdentity.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(authority.contains(
            "struct SkillOfferReviewSubjectRecord"))
        XCTAssertTrue(authority.contains(
            "enum SkillOfferReviewSubjectOutcome"))
        XCTAssertTrue(review.contains(
            "struct ResolveSkillOfferReviewDestination"))
        XCTAssertTrue(review.contains(
            "resolveProposedSkillOfferSubject("))
        XCTAssertFalse(review.contains("idempotencyKey:"))
        XCTAssertFalse(review.contains("effect.perform"))
        XCTAssertFalse(review.contains("ExecuteSkill"))
        XCTAssertTrue(store.contains(
            "WHERE reviewID = ?"))
        XCTAssertTrue(store.contains(
            "NOT EXISTS (\n                          SELECT 1 FROM skillOfferDismissal"))
        XCTAssertTrue(settings.contains(
            "services.resolveSkillOfferReviewDestination(\n                offer.id)"))
        XCTAssertTrue(settings.contains(
            "services.pendingRoute = .meeting(meetingID)"))
        XCTAssertTrue(settings.contains(
            "services.pendingRoute = .commitments(.commitment(commitmentID))"))
        XCTAssertTrue(settings.contains(
            "openWindow(id: \"main\", value: MainWindowIdentity.primary)"))
        XCTAssertTrue(settings.contains("dismissWindow()"))
        XCTAssertTrue(proposal.contains(
            "settings-skill-proposal-review-"))
        XCTAssertTrue(proposal.contains("Review in menu bar"))
        XCTAssertFalse(proposal.contains("offer.subject"))
        XCTAssertTrue(services.contains("usesTemporaryMeetingStore"))
        XCTAssertTrue(services.contains(
            "-simulate-skill-proposal-review-unavailable"))
        XCTAssertTrue(mainIdentity.contains(
            "enum MainWindowIdentity: String, Codable, Hashable, Sendable"))
        XCTAssertTrue(app.contains("for: MainWindowIdentity.self"))
        XCTAssertTrue(app.contains("defaultValue:"))
        XCTAssertTrue(decisions.contains("## D340"))
    }

    func testFailedSkillRecoveryKeepsExactSubjectAndEffectAuthoritySeparate() throws {
        let skill = try Self.contents(of: "Sources/PortavozCore/Skill.swift")
        let subject = try Self.contents(
            of: "Sources/PortavozCore/SkillSubject.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SkillExecutionSubject.swift")
        let subjectStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecutionSubject.swift")
        let execution = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecution.swift")
        let recovery = try Self.contents(
            of: "Sources/ApplicationKit/SkillReceiptInspection.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsView.swift")
        let receiptNavigation = try Self.contents(
            of: "Sources/portavoz-app/SettingsSkillReceiptNavigation.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(subject.contains("public enum SkillSubject"))
        XCTAssertTrue(subject.contains("case meeting(MeetingID)"))
        XCTAssertTrue(subject.contains("case commitment(CommitmentID)"))
        XCTAssertTrue(subject.contains("case calendarEvent(String)"))
        XCTAssertTrue(subject.contains("matches.count == 1"))
        XCTAssertTrue(skill.contains("public let subjectKind: SkillSubject.Kind"))
        XCTAssertTrue(skill.contains("public let subject: SkillSubject"))
        XCTAssertTrue(skill.contains("case invalidSubject"))
        XCTAssertTrue(schema.contains("registerMigration(\"v41\")"))
        XCTAssertTrue(schema.contains("skillExecutionSubject"))
        XCTAssertTrue(schema.contains("failureCategory"))
        XCTAssertTrue(schema.contains("onDelete: .cascade"))
        for forbidden in [
            "offerKey", "idempotencyKey", "argument", "destination",
            "recipient", "title", "transcript",
        ] {
            XCTAssertFalse(
                schema.contains(forbidden),
                "recovery subject schema must stay content-free: \(forbidden)")
        }
        XCTAssertTrue(subjectStore.contains(
            "Legacy pre-v41 receipts deliberately return nil"))
        XCTAssertFalse(subjectStore.contains("idempotencyKey"))
        XCTAssertTrue(execution.contains("recordSkillExecutionSubject("))
        XCTAssertTrue(execution.contains("state, failureCategory, attempt"))
        XCTAssertTrue(recovery.contains(
            "struct ResolveSkillReceiptRecoveryDestination"))
        XCTAssertTrue(recovery.contains(
            "let recoveryAvailability = try await recoveryAvailability(audit: audit)"))
        XCTAssertTrue(recovery.contains(
            "recoveryAvailability: recoveryAvailability"))
        XCTAssertTrue(recovery.contains("case verifyExternally"))
        XCTAssertFalse(recovery.contains("effect.perform"))
        XCTAssertFalse(recovery.contains("ExecuteSkill"))
        XCTAssertFalse(recovery.contains("idempotencyKey"))
        XCTAssertTrue(receiptSheet.contains(
            "skill-receipt-recovery-action"))
        XCTAssertTrue(receiptSheet.contains(
            "openReceiptDestination: (SkillOfferReviewDestination) -> Void"))
        XCTAssertFalse(receiptSheet.contains("services.pendingRoute ="))
        XCTAssertFalse(receiptSheet.contains("openWindow(id:"))
        XCTAssertTrue(receiptNavigation.contains(
            "services.pendingRoute = .meeting(meetingID)"))
        XCTAssertTrue(receiptNavigation.contains(
            "services.pendingRoute = .commitments(.commitment(commitmentID))"))
        XCTAssertTrue(settings.contains(
            "openWindow(id: \"main\", value: MainWindowIdentity.primary)"))
        XCTAssertTrue(settings.contains(
            "onDismiss: openPendingSkillReceiptDestination"))
        XCTAssertTrue(receiptNavigation.contains("weak var window: NSWindow?"))
        XCTAssertTrue(settings.contains("SettingsWindowCapture(reference:"))
        XCTAssertTrue(receiptNavigation.contains("settingsWindow?.close()"))
        XCTAssertFalse(settings.contains("NSApp.keyWindow"))
        XCTAssertFalse(receiptNavigation.contains("NSApp.keyWindow"))
        XCTAssertFalse(receiptSheet.contains("idempotencyKey"))
        XCTAssertTrue(decisions.contains("## D341"))
    }

    func testSkillReceiptSourceReviewIsInertPolicyIndependentAndFailClosed() throws {
        let inspection = try Self.contents(
            of: "Sources/ApplicationKit/SkillReceiptInspection.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SkillsControl.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsView.swift")
        let receiptNavigation = try Self.contents(
            of: "Sources/portavoz-app/SettingsSkillReceiptNavigation.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(inspection.contains(
            "protocol SkillReceiptAuditReading: Sendable"))
        XCTAssertTrue(inspection.contains(
            "struct ResolveSkillReceiptContextDestination"))
        XCTAssertTrue(inspection.contains(
            "private let store: any SkillReceiptAuditReading"))
        XCTAssertTrue(inspection.contains(
            "contextAvailability: Self.contextAvailability(audit: audit)"))
        XCTAssertTrue(inspection.contains(
            "switch Self.recoveryPolicyRequirement(audit: audit)"))
        XCTAssertTrue(inspection.contains("case .currentPolicy:"))
        XCTAssertTrue(inspection.contains(
            "let policy = try await store.skillExecutionPolicy()"))
        XCTAssertTrue(inspection.contains(
            "return .resolved(.verifyExternally)"))
        XCTAssertTrue(inspection.contains("try Task.checkCancellation()"))
        XCTAssertTrue(inspection.contains(
            "guard audit.record.state != .failed,"))
        XCTAssertTrue(inspection.contains(
            "LoadSkillReceiptInspection.validateAndProject(audit)"))
        XCTAssertFalse(inspection.contains("effect.perform"))
        XCTAssertFalse(inspection.contains("ExecuteSkill"))
        XCTAssertFalse(inspection.contains("idempotencyKey"))
        XCTAssertTrue(services.contains(
            "-simulate-skill-receipt-context-unavailable"))
        XCTAssertTrue(services.contains(
            "-simulate-skill-receipt-policy-unavailable"))
        XCTAssertTrue(services.contains("usesTemporaryMeetingStore"))
        XCTAssertTrue(receiptSheet.contains(
            "skill-receipt-context-action"))
        XCTAssertTrue(receiptSheet.contains(
            "skill-receipt-context-error"))
        XCTAssertTrue(receiptSheet.contains(
            "skill-receipt-context-retry"))
        XCTAssertTrue(receiptSheet.contains(
            "openReceiptDestination: (SkillOfferReviewDestination) -> Void"))
        XCTAssertFalse(receiptSheet.contains("services.pendingRoute ="))
        XCTAssertTrue(settings.contains(
            "@State private var pendingSkillReceiptDestination"))
        XCTAssertTrue(settings.contains(
            "onDismiss: openPendingSkillReceiptDestination"))
        XCTAssertTrue(receiptNavigation.contains(
            "enum SettingsSkillReceiptNavigation"))
        XCTAssertFalse(receiptNavigation.contains("effect.perform"))
        XCTAssertTrue(decisions.contains("## D359"))
        XCTAssertTrue(decisions.contains("## D369"))
    }

    func testSkillReceiptDismissalRestoresLocalFocusWithoutCompetingWithRecovery() throws {
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsView.swift")
        let focusState = try Self.contents(
            of: "Sources/portavoz-app/SettingsSkillReceiptFocusState.swift")
        let skills = try Self.contents(
            of: "Sources/portavoz-app/SkillsSettingsSection.swift")
        let activity = try Self.contents(
            of: "Sources/portavoz-app/SkillActivitySection.swift")
        let receiptSheet = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptInspectionSheet.swift")
        let uiRunner = try Self.contents(of: "scripts/run-ui-tests.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(settings.contains(
            "@State private var skillReceiptFocus = SettingsSkillReceiptFocusState()"))
        XCTAssertTrue(settings.contains("skillReceiptFocus.beginInspection"))
        XCTAssertTrue(settings.contains("skillReceiptFocus.clear()"))
        XCTAssertTrue(settings.contains("skillReceiptFocus.restoreAfterDismissal"))
        XCTAssertTrue(focusState.contains(
            "try await sleep(.milliseconds(200))"))
        XCTAssertTrue(focusState.contains("restorationTask?.cancel()"))
        XCTAssertTrue(focusState.contains(
            "guard let self, restorationGeneration == generation"))
        XCTAssertTrue(settings.contains(
            "selectedSkillReceipt == nil && category == .skills"))
        XCTAssertTrue(skills.contains(
            "focusRequestID: receiptFocusRequestID"))
        XCTAssertTrue(activity.contains(
            "@FocusState private var focusedReceiptID: UUID?"))
        XCTAssertTrue(activity.contains(
            "@AccessibilityFocusState private var accessibilityFocusedReceiptID"))
        XCTAssertTrue(activity.contains(
            ".onChange(of: focusRequestID, initial: true)"))
        XCTAssertTrue(activity.contains("await Task.yield()"))
        XCTAssertTrue(activity.contains(
            "guard self.focusRequestID == focusRequestID"))
        XCTAssertTrue(activity.contains(
            ".focusable(interactions: .activate)"))
        XCTAssertTrue(activity.contains(
            ".focused($focusedReceiptID, equals: receipt.proposalID)"))
        XCTAssertTrue(activity.contains(
            ".accessibilityFocused("))
        XCTAssertFalse(receiptSheet.contains("focusedReceiptID"))
        XCTAssertFalse(receiptSheet.contains("focusRequestID"))
        XCTAssertTrue(uiRunner.contains("AppleKeyboardUIMode"))
        XCTAssertTrue(uiRunner.contains(
            """
            cleanup_ui_test_runner() {
              restore_keyboard_ui_mode
            }
            trap cleanup_ui_test_runner EXIT HUP INT TERM
            """))
        XCTAssertTrue(decisions.contains("## D342"))
    }

    func testSkillRetryKeepsOneProposalIdentityFromPreviewToEffect() throws {
        let flow = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailFlowState.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Skills.swift")
        let appAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingSkills.swift")
        let sheet = try Self.contents(
            of: "Sources/portavoz-app/SkillConfirmSheet.swift")
        let factory = try Self.contents(
            of: "Sources/ApplicationKit/MeetingSkillOffers.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(flow.contains("let proposalID: UUID"))
        XCTAssertTrue(flow.contains("let proposedAt: Date"))
        XCTAssertTrue(coordinator.contains("proposalID: target.proposalID"))
        XCTAssertTrue(coordinator.contains("proposedAt: target.proposedAt"))
        XCTAssertTrue(appAdapter.contains("skillExecution(idempotencyKey:"))
        XCTAssertTrue(appAdapter.contains("at: proposedAt).proposal"))
        XCTAssertFalse(appAdapter.contains("at: Date()).proposal"))
        XCTAssertTrue(appAdapter.contains("guard usesTemporaryStore,"))
        XCTAssertTrue(sheet.contains("skill-confirm-error"))
        XCTAssertTrue(factory.contains("proposalID: UUID = UUID()"))
        XCTAssertTrue(factory.contains("id: proposalID"))
        XCTAssertTrue(decisions.contains("## D321"))
    }

    func testMenuBarBriefUsesOpaqueCalendarIdentityAndExactApprovedMaterial() throws {
        let event = try Self.contents(of: "Sources/PortavozCore/UpcomingEvent.swift")
        let calendar = try Self.contents(
            of: "Sources/IntegrationsKit/CalendarAttendeeSource.swift")
        let offers = try Self.contents(
            of: "Sources/ApplicationKit/PreMeetingBriefOffers.swift")
        let skills = try Self.contents(of: "Sources/ApplicationKit/LocalSkills.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MenuBarModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MenuBar.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MenuBarView.swift")
        let sheets = try Self.contents(
            of: "Sources/portavoz-app/MenuBarBriefSheets.swift")
        let app = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(event.contains("public let id: String"))
        XCTAssertTrue(event.contains("isValidIdentity"))
        XCTAssertFalse(event.contains("public var id: String"))
        XCTAssertTrue(calendar.contains("event.eventIdentifier"))
        XCTAssertTrue(calendar.contains("event(withIdentifier: identifier)"))
        XCTAssertTrue(calendar.contains("guard Self.hasAccess"))
        XCTAssertTrue(offers.contains("let isRetryable = execution.state == .failed"))
        XCTAssertTrue(offers.contains(
            "active: isRetryable ? [offer.registration(at: now())] : []"))
        XCTAssertTrue(offers.contains("return isRetryable ? offer : nil"))
        XCTAssertTrue(offers.contains("dismissedSkillOffers"))
        XCTAssertTrue(offers.contains("public init?(event: UpcomingEvent)"))
        XCTAssertTrue(offers.contains("guard UpcomingEvent.isValidIdentity(eventID)"))
        XCTAssertTrue(offers.contains("existing.skillID == PreMeetingBriefSkill.id"))
        XCTAssertTrue(offers.contains(
            "existing.skillVersion == PreMeetingBriefSkill.version"))
        XCTAssertTrue(offers.contains("existing.idempotencyKey == idempotencyKey"))
        XCTAssertTrue(offers.contains(
            "existing.proposalID == requested || existing.state == .failed"))
        XCTAssertTrue(skills.contains("private let material: MeetingBrief"))
        XCTAssertTrue(skills.contains("delivery.deliver(material)"))
        XCTAssertFalse(skills.contains("brief.execute(event)"))
        XCTAssertTrue(model.contains("let proposalID: UUID"))
        XCTAssertTrue(model.contains("approvedBrief: target.brief"))
        XCTAssertTrue(adapter.contains("currentEvent == offer.event"))
        XCTAssertTrue(adapter.contains("ExecuteSkill("))
        XCTAssertTrue(adapter.contains(
            "usesTemporaryStore && arguments.contains(\"-seed-brief\")"))
        XCTAssertTrue(sheets.contains("menu-bar-brief-confirm-submit"))
        XCTAssertTrue(view.contains("menu-bar-brief-prepare"))
        XCTAssertTrue(view.contains("menu-bar-brief-dismiss"))
        XCTAssertTrue(app.contains("arguments.contains(\"-use-temp-store\")"))
        XCTAssertTrue(app.contains("arguments.contains(\"-show-menu-bar-content\")"))
        XCTAssertTrue(decisions.contains("## D322"))
    }

    func testLocalSkillsAreContractsOverExistingWorkAndStayOffTheNetwork() throws {
        let skills = try Self.contents(
            of: "Sources/ApplicationKit/LocalSkills.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // Each effect delegates to the use case that already owns the work,
        // so a skill can never become a second implementation that drifts.
        XCTAssertTrue(skills.contains("RecapComposer.compose("))
        XCTAssertTrue(skills.contains("export.execute(ExportMeetingBundleRequest("))
        XCTAssertTrue(skills.contains("delivery.deliver(material)"))

        // No platform framework and no transport reaches this layer.
        for forbidden in [
            "import EventKit", "import SwiftUI", "import AppKit",
            "URLSession", "URLRequest",
        ] {
            XCTAssertFalse(skills.contains(forbidden), forbidden)
        }
        XCTAssertFalse(skills.contains(".sendRemote"))

        // Audio would move far more than one confirmation previewed.
        XCTAssertTrue(skills.contains("includeAudio: false"))
        XCTAssertTrue(decisions.contains("## D295"))
    }

    func testEmailRecapEgressIsExplicitPreviewedAndPlatformBounded() throws {
        let external = try Self.contents(
            of: "Sources/ApplicationKit/ExternalSkills.swift")
        let appAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingSkills.swift")
        let sheet = try Self.contents(
            of: "Sources/portavoz-app/SkillConfirmSheet.swift")
        let trust = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailTrustSection.swift")
        let receiptPresentation = try Self.contents(
            of: "Sources/portavoz-app/SkillReceiptPresentation.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(external.contains("enum ExternalSkills"))
        XCTAssertTrue(external.contains("EmailRecapDraftSkill.definition"))
        XCTAssertTrue(external.contains(".sendRemote"))
        XCTAssertTrue(external.contains(".explicitPerProposal"))
        XCTAssertTrue(external.contains("RecapComposer.compose("))
        for forbidden in [
            "import AppKit", "import SwiftUI", "URLSession", "URLRequest",
        ] {
            XCTAssertFalse(external.contains(forbidden), forbidden)
        }

        let systemOpenerStart = try XCTUnwrap(
            appAdapter.range(of: "struct AppSystemEmailDraftOpener"))
        let disposableOpenerStart = try XCTUnwrap(appAdapter.range(
            of: "private struct AppDisposableEmailDraftOpener",
            range: systemOpenerStart.upperBound..<appAdapter.endIndex))
        let systemOpener = appAdapter[
            systemOpenerStart.lowerBound..<disposableOpenerStart.lowerBound]
        XCTAssertTrue(systemOpener.contains(
            "let service = NSSharingService(named: .composeEmail)"))
        XCTAssertTrue(systemOpener.contains("service.recipients = []"))
        XCTAssertTrue(systemOpener.contains("service.subject = subject"))
        XCTAssertTrue(systemOpener.contains("service.perform(withItems: items)"))
        XCTAssertTrue(appAdapter.contains("AppDisposableEmailDraftOpener"))
        XCTAssertFalse(systemOpener.contains("URLSession"))
        XCTAssertFalse(systemOpener.contains("NSAppleScript"))

        XCTAssertTrue(sheet.contains(
            "skill-confirm-email-recipient-policy"))
        XCTAssertTrue(sheet.contains("skill-confirm-email-boundary"))
        XCTAssertTrue(sheet.contains("you still press Send"))
        XCTAssertTrue(trust.contains(
            "SkillReceiptPresentation.meetingDetailTitle("))
        XCTAssertTrue(receiptPresentation.contains(
            "Email recap draft — handoff status unknown"))
        XCTAssertTrue(receiptPresentation.contains("Handoff status unknown"))
        XCTAssertTrue(decisions.contains("## D327"))
    }

    func testSecretGistSkillReusesCanonicalEgressAndCannotDuplicateTransport() throws {
        let external = try Self.contents(
            of: "Sources/ApplicationKit/ExternalSkills.swift")
        let appAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingSkills.swift")
        let documents = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDocuments.swift")
        let publisher = try Self.contents(
            of: "Sources/IntegrationsKit/GistPublisher.swift")
        let sheet = try Self.contents(
            of: "Sources/portavoz-app/SkillConfirmSheet.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Skills.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(external.contains("SecretGistPublishSkill.definition"))
        XCTAssertTrue(external.contains("SecretGistPublishing"))
        XCTAssertTrue(external.contains("case outcomeUnknown"))
        XCTAssertFalse(external.contains("GistPublisher("))
        XCTAssertFalse(external.contains("URLSession"))
        XCTAssertTrue(appAdapter.contains(
            "let eventID = DataEgressEventID(rawValue: proposalID)"))
        XCTAssertTrue(appAdapter.contains(
            "URLSessionDataEgressGateway("))
        XCTAssertTrue(appAdapter.contains("makeEventID: { eventID }"))
        XCTAssertTrue(appAdapter.contains("AppSecretGistSkillPublisher"))
        XCTAssertTrue(appAdapter.contains("didStartRemoteAttempt = true"))
        XCTAssertTrue(appAdapter.contains("await output.remoteAttemptStarted()"))
        XCTAssertTrue(appAdapter.contains("AppDisposableGistEgressGateway"))
        XCTAssertTrue(documents.contains("GistPublisher(token: token, gateway: gateway)"))
        XCTAssertFalse(appAdapter.contains("URLSession.shared"))
        XCTAssertFalse(appAdapter.contains("NSAppleScript"))
        XCTAssertFalse(publisher.contains("request.url!"))
        XCTAssertFalse(publisher.contains(
            "URL(string: \"https://api.github.com/gists\")!"))
        XCTAssertTrue(sheet.contains("skill-confirm-gist-destination"))
        XCTAssertTrue(sheet.contains("skill-confirm-gist-boundary"))
        XCTAssertTrue(sheet.contains("the full document leaves this Mac"))
        XCTAssertTrue(sheet.contains("ReadOnlySkillDocumentText"))
        XCTAssertTrue(sheet.contains("textView.isEditable = false"))
        XCTAssertTrue(sheet.contains("textView.isSelectable = true"))
        for resultControl in [
            "gist-result-url", "gist-result-copy-link",
            "gist-result-open-link", "gist-result-dismiss",
        ] {
            XCTAssertTrue(sheet.contains(resultControl), resultControl)
        }
        XCTAssertTrue(coordinator.contains("return .gistPublished(outputURL)"))
        XCTAssertTrue(coordinator.contains("return .gistOutcomeUnknown("))
        XCTAssertFalse(coordinator.contains("flow.alert"))
        XCTAssertTrue(decisions.contains("## D328"))
    }

    func testGitHubIssueSkillReusesCanonicalEgressAndCannotDuplicateTransport() throws {
        let external = try Self.contents(
            of: "Sources/ApplicationKit/ExternalSkills.swift")
        let domain = try Self.contents(
            of: "Sources/ApplicationKit/GitHubIssueSkill.swift")
        let repository = try Self.contents(
            of: "Sources/PortavozCore/GitHubRepository.swift")
        let appAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+GitHubIssueSkill.swift")
        let exporter = try Self.contents(
            of: "Sources/IntegrationsKit/IssueExporters.swift")
        let sheet = try Self.contents(
            of: "Sources/portavoz-app/GitHubIssueSkillSheet.swift")
        let actionItems = try Self.contents(
            of: "Sources/portavoz-app/MeetingActionItemsView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let githubStart = try XCTUnwrap(exporter.range(
            of: "public struct GitHubIssuesExporter"))
        let linearStart = try XCTUnwrap(exporter.range(
            of: "// MARK: - Linear",
            range: githubStart.upperBound..<exporter.endIndex))
        let githubExporter = exporter[
            githubStart.lowerBound..<linearStart.lowerBound]

        XCTAssertTrue(external.contains("GitHubIssueCreateSkill.definition"))
        XCTAssertTrue(domain.contains(".actionItem(draft.actionItemID)"))
        XCTAssertTrue(domain.contains("case outcomeUnknown"))
        XCTAssertTrue(domain.contains(".explicitPerProposal"))
        XCTAssertTrue(domain.contains("maximumTimestamp"))
        XCTAssertTrue(domain.contains(
            "seconds <= GitHubIssueCitation.maximumTimestamp"))
        XCTAssertFalse(domain.contains("import IntegrationsKit"))
        XCTAssertFalse(domain.contains("URLSession"))
        XCTAssertFalse(domain.contains("GitHubIssuesExporter("))
        for trap in ["try!", "as!", "fatalError", "preconditionFailure"] {
            XCTAssertFalse(repository.contains(trap), trap)
        }

        XCTAssertTrue(appAdapter.contains(
            "let eventID = DataEgressEventID(rawValue: proposalID)"))
        XCTAssertTrue(appAdapter.contains("GitHubIssuesExporter("))
        XCTAssertTrue(appAdapter.contains(
            "URLSessionDataEgressGateway("))
        XCTAssertTrue(appAdapter.contains(
            "AppDisposableGitHubIssueEgressGateway"))
        XCTAssertTrue(appAdapter.contains(
            "URLSessionConfiguration.ephemeral"))
        XCTAssertTrue(appAdapter.contains(
            "configuration.timeoutIntervalForRequest = requestTimeout"))
        XCTAssertTrue(appAdapter.contains(
            "configuration.waitsForConnectivity = false"))
        XCTAssertFalse(appAdapter.contains("URLSession.shared"))

        XCTAssertTrue(githubExporter.contains(
            "guard let repository = GitHubRepository(repository)"))
        XCTAssertTrue(githubExporter.contains(
            "url.pathComponents[1] == expectedRepository.owner"))
        XCTAssertTrue(githubExporter.contains(
            "url.pathComponents[2] == expectedRepository.name"))
        XCTAssertTrue(githubExporter.contains(
            "UInt64(url.pathComponents[4]).map({ $0 > 0 }) == true"))
        XCTAssertFalse(githubExporter.contains("request.url!"))

        for control in [
            "github-issue-sheet", "github-issue-action-item",
            "github-issue-repository", "github-issue-review",
            "github-issue-preview-repository", "github-issue-preview-title",
            "github-issue-preview-body",
            #"github-issue-citation-\(index)"#,
            "github-issue-boundary", "github-issue-confirm",
            "github-issue-result-title", "github-issue-result-url",
        ] {
            XCTAssertTrue(sheet.contains(control), control)
        }
        XCTAssertTrue(actionItems.contains(
            #"action-item-\(item.id.uuidString)-github"#))
        XCTAssertTrue(decisions.contains("## D434"))
        XCTAssertTrue(decisions.contains("## D442"))
    }

    func testStandingRuleAuthorityStaysClosedLocalAndInspectable() throws {
        let domain = try Self.contents(
            of: "Sources/PortavozCore/StandingSkillRule.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/StandingSkillRules.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let ruleSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+StandingSkillRule.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+StandingSkillRule.swift")
        let executionDomain = try Self.contents(
            of: "Sources/PortavozCore/StandingSkillExecution.swift")
        let executionApplication = try Self.contents(
            of: "Sources/ApplicationKit/StandingPreMeetingBriefs.swift")
        let executionSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+StandingSkillExecution.swift")
        let executionStorage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+StandingSkillExecution.swift")
        let supervisor = try Self.contents(
            of: "Sources/portavoz-app/StandingPreMeetingBriefSupervisor.swift")
        let automationCenter = try Self.contents(
            of: "Sources/ApplicationKit/StandingSkillAutomationCenter.swift")
        let historyStorage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+StandingSkillHistory.swift")
        let appServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StandingSkills.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/StandingSkillRulesSection.swift")
        let eventSource = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MenuBar.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(domain.contains("maximumRuleCount = 32"))
        XCTAssertTrue(domain.contains("maximumDailyExecutionCount = 8"))
        XCTAssertTrue(domain.contains("case upcomingCalendarEvent"))
        XCTAssertTrue(domain.contains("case anyUpcomingCalendarEvent"))
        XCTAssertTrue(domain.contains("case preparePreMeetingBrief"))
        for forbidden in [
            "public let meetingID", "public let title", "public let attendees",
            "public let transcript", "public let destination",
            "public let provider", "public let credentials", "URLSession",
            "import StorageKit",
        ] {
            XCTAssertFalse(domain.contains(forbidden), forbidden)
        }

        XCTAssertTrue(application.contains(
            "case prepareEveryUpcomingBrief"))
        XCTAssertTrue(application.contains(
            "PreMeetingBriefSkill.definition"))
        XCTAssertTrue(application.contains("definition.isReversible"))
        XCTAssertTrue(application.contains(
            "!definition.declaresExternalEffect"))
        XCTAssertTrue(application.contains(
            "!definition.capabilities.contains(.writeLocalFile)"))
        XCTAssertTrue(application.contains("case staleDefinition"))
        for forbidden in [
            "ExecuteSkill", "SkillEffectPerforming", "URLSession",
            "EventKit", "AppKit", "SwiftUI",
        ] {
            XCTAssertFalse(application.contains(forbidden), forbidden)
        }

        XCTAssertTrue(schema.contains("public static let version = 51"))
        XCTAssertTrue(schema.contains(
            "registerStandingSkillRuleMigration"))
        XCTAssertTrue(schema.contains(
            "registerStandingSkillExecutionMigration"))
        XCTAssertTrue(ruleSchema.contains(
            "registerMigration(\"v46\")"))
        XCTAssertTrue(ruleSchema.contains(
            "table.uniqueKey([\"trigger\", \"subjectPredicate\", \"action\"])"))
        XCTAssertTrue(storage.contains("SELECT COUNT(*)"))
        XCTAssertTrue(storage.contains("maximumRuleCount"))
        XCTAssertTrue(storage.contains("invalid persisted row"))
        XCTAssertFalse(storage.contains("SELECT *"))
        XCTAssertTrue(decisions.contains("## D435"))

        XCTAssertTrue(executionDomain.contains(
            "maximumAutomaticAttempts = 3"))
        XCTAssertTrue(executionDomain.contains(
            "maximumPendingExecutionCount = 32"))
        XCTAssertTrue(executionDomain.contains(
            "maximumPayloadByteCount = 128 * 1_024"))
        XCTAssertTrue(executionApplication.contains(
            "maximumPreparationLeadTime: TimeInterval = 2 * 60 * 60"))
        XCTAssertTrue(executionApplication.contains(
            "timeout: Duration = .seconds(30)"))
        XCTAssertTrue(executionApplication.contains(
            "isSameEventSnapshot(currentEvent, event)"))
        XCTAssertTrue(executionDomain.contains(
            "canonicalStartMilliseconds"))
        XCTAssertTrue(executionSchema.contains(
            "registerMigration(\"v47\")"))
        XCTAssertTrue(executionSchema.contains(
            "registerMigration(\"v48\")"))
        XCTAssertTrue(executionSchema.contains(
            "CREATE TRIGGER standingSkillExecutionAuthority_no_update"))
        XCTAssertTrue(executionSchema.contains(
            "CREATE TRIGGER standingSkillArtifact_no_update"))
        XCTAssertTrue(executionStorage.contains(
            "standingOccurrenceRefusal"))
        XCTAssertTrue(executionStorage.contains(
            "standingCapacityRefusal"))
        XCTAssertTrue(supervisor.contains(
            "scheduleNextStandingWake"))
        XCTAssertTrue(supervisor.contains("static func nextWakeDate"))
        XCTAssertTrue(supervisor.contains("byAdding: .day"))
        XCTAssertTrue(supervisor.contains(
            "guard !snapshot.isPaused else {\n"
                + "            cancelScheduledWake()\n"
                + "            return\n"
                + "        }"))
        XCTAssertTrue(supervisor.contains(
            "suspendForCapture"))
        XCTAssertFalse(supervisor.contains("Task.sleep(for: .seconds(1"))
        XCTAssertTrue(decisions.contains("## D436"))

        XCTAssertTrue(automationCenter.contains(
            "defaultHistoryLimit = 20"))
        XCTAssertTrue(automationCenter.contains(
            "maximumHistoryLimit = 50"))
        XCTAssertTrue(historyStorage.contains(
            "FROM standingSkillExecutionAuthority AS authority"))
        XCTAssertFalse(historyStorage.contains(
            "skillExecutionReceipts("))
        XCTAssertTrue(appServices.contains("reconcileNow"))
        XCTAssertTrue(supervisor.contains(
            "func retryNow(_ proposalID: UUID) async"))
        XCTAssertTrue(appServices.contains(
            "standingPreMeetingBriefs.retryNow(proposalID)"))
        XCTAssertFalse(appServices.contains(
            "ExecuteStandingPreMeetingBrief("))
        for identifier in [
            "settings-standing-preview", "settings-standing-daily-limit",
            "settings-standing-create", "settings-standing-status",
            "settings-standing-enabled", "settings-standing-delete",
            "settings-standing-history", "settings-standing-history-retry-",
            "settings-standing-history-review-", "standing-brief-sheet",
            "standing-brief-privacy",
        ] {
            XCTAssertTrue(settings.contains(identifier), identifier)
        }
        XCTAssertTrue(decisions.contains("## D437"))
        XCTAssertTrue(supervisor.contains("func reconcileNow() async throws"))
        XCTAssertTrue(supervisor.contains("restorePendingWork(for: scope)"))
        XCTAssertTrue(supervisor.contains(
            "guard generation == workerGeneration else { return }"))
        XCTAssertFalse(supervisor.contains("try? await reconcile("))
        XCTAssertTrue(appServices.contains(
            "try await standingPreMeetingBriefs.reconcileNow()"))
        XCTAssertTrue(appServices.contains(
            "try await standingPreMeetingBriefs.retryNow(proposalID)"))
        XCTAssertTrue(executionApplication.contains(
            "try await cancelConfirmedClaim(record.proposalID)"))
        XCTAssertTrue(decisions.contains("## D439"))
        XCTAssertTrue(settings.contains(
            "guard !isBusy, !externalMutationInFlight, !mutationFailed"))
        XCTAssertTrue(settings.contains(
            "let callerCancelled = Task.isCancelled"))
        XCTAssertTrue(settings.contains(
            "private var durableMutationDisabled: Bool"))
        XCTAssertTrue(settings.contains(
            "isBusy || externalMutationInFlight || mutationFailed"))
        XCTAssertTrue(eventSource.contains(
            "-simulate-standing-reconciliation-cancellation-once"))
        XCTAssertTrue(decisions.contains("## D440"))
        XCTAssertTrue(supervisor.contains("withTaskCancellationHandler"))
        XCTAssertTrue(supervisor.contains("cancelReconciliationWaiter"))
        XCTAssertTrue(supervisor.contains(
            "UUID: ReconciliationContinuation"))
        XCTAssertTrue(decisions.contains("## D441"))
        XCTAssertTrue(supervisor.contains(
            "guard captureState.current != .inactive else {"))
        XCTAssertTrue(supervisor.contains(
            "kick()\n            return\n        }"))
        XCTAssertTrue(decisions.contains("## D443"))
    }

    func testCommandLibraryReadsEnterThroughApplicationKitComposition() throws {
        for file in ["CLIAsk.swift", "CLIMcp.swift", "CLIMeetings.swift"] {
            let source = try Self.contents(of: "Sources/portavoz-cli/\(file)")
            XCTAssertFalse(source.contains("import StorageKit"), file)
            XCTAssertFalse(source.contains("MeetingStore("), file)
            XCTAssertTrue(source.contains("CLIComposition"), file)
        }
        let composition = try Self.contents(of: "Sources/portavoz-cli/CLIComposition.swift")
        XCTAssertTrue(composition.contains("let library: QueryMeetingLibrary"))
        XCTAssertTrue(composition.contains("let ask: AskMeetings"))
    }

    func testProductCLIWorkflowsEnterThroughApplicationKitComposition() throws {
        let files = [
            "CLITranscribe.swift", "CLIDiarize.swift", "CLISummarize.swift",
            "CLIRefine.swift", "CLIExport.swift", "CLIIssues.swift",
            "CLIVoice.swift", "CLIModels.swift",
        ]
        let forbiddenImports = [
            "ModelStoreKit", "TranscriptionKit", "DiarizationKit",
            "IntelligenceKit", "IntegrationsKit", "StorageKit",
        ]
        let forbiddenConcreteSymbols = [
            "ModelStore(", "WhisperEngine", "PyannoteDiarizer(",
            "MeetingStore(", "MeetingExporter.", "URLSessionDataEgressGateway(",
            "VoiceprintStore(",
        ]

        for file in files {
            let source = try Self.contents(of: "Sources/portavoz-cli/\(file)")
            XCTAssertTrue(source.contains("import ApplicationKit"), file)
            for module in forbiddenImports {
                XCTAssertFalse(source.contains("import \(module)"), "\(file): \(module)")
            }
            for symbol in forbiddenConcreteSymbols {
                XCTAssertFalse(source.contains(symbol), "\(file): \(symbol)")
            }
            XCTAssertFalse(source.contains("FileManager.default"), file)
        }

        let composition = try Self.contents(of: "Sources/portavoz-cli/CLIComposition.swift")
        let adapters = try Self.contents(of: "Sources/portavoz-cli/CLIProductAdapters.swift")
        for workflow in [
            "TranscribeAudioFile", "DiarizeAudioFile", "SummarizeAudioFile",
            "RefineMeetingUseCases", "ExportMeetingDocument",
            "PublishMeetingActionItems", "ManageLocalVoiceIdentity", "ManageLocalModels",
        ] {
            XCTAssertTrue(
                composition.contains(workflow) || adapters.contains(workflow),
                workflow)
        }
    }

    func testLegacyCLIOptionsAreBoundedAndCaptureTasksAreDrained() throws {
        let optionCommands = [
            "CLIAsk.swift", "CLIBench.swift", "CLIBenchFTS.swift",
            "CLIBenchLive.swift", "CLIDer.swift", "CLIDiarize.swift",
            "CLIRecord.swift",
        ]
        for file in optionCommands {
            let source = try Self.contents(of: "Sources/portavoz-cli/\(file)")
            XCTAssertTrue(source.contains("CLIOptionValue."), file)
            XCTAssertFalse(
                source.range(
                    of: #"(?:Int|Float|Double)\(arguments\[index\]\)\s*\?\?"#,
                    options: .regularExpression) != nil,
                file)
        }

        let support = try Self.contents(of: "Sources/portavoz-cli/CLISupport.swift")
        XCTAssertTrue(support.contains("maximumFTSSegments = 1_000_000"))
        XCTAssertTrue(support.contains("multipliedReportingOverflow"))
        XCTAssertTrue(support.contains("value.isFinite"))

        let record = try Self.contents(of: "Sources/portavoz-cli/CLIRecord.swift")
        XCTAssertTrue(record.contains("finishLiveJobs("))
        XCTAssertTrue(record.contains("_ = await session.stop()"))
        XCTAssertTrue(
            record.range(
                of: #"jobs: liveJobs,\s+cancel: true"#,
                options: .regularExpression) != nil)
        XCTAssertTrue(record.contains("catch is CancellationError"))
        XCTAssertFalse(record.contains("Task.sleep(nanoseconds: UInt64(seconds)"))

        let benchmark = try Self.contents(of: "Sources/portavoz-cli/CLIBench.swift")
        XCTAssertTrue(benchmark.contains("cancelAndDrain("))
        XCTAssertTrue(benchmark.contains("batch.cancel()"))
        XCTAssertTrue(benchmark.contains("_ = await feeder.value"))
        XCTAssertTrue(benchmark.contains("_ = await batch.value"))
        XCTAssertFalse(benchmark.contains("Task.sleep(nanoseconds: UInt64(seconds)"))
    }

    func testCompanionBYOKEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        // Live detection split into its own extension file (D138); the BYOK
        // wiring pins apply to the pair.
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
            + Self.contents(
                of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let refresh = try Self.contents(of: "Sources/portavoz-app/CompanionRefresh.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let appApplication = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressGateway"))
        XCTAssertFalse(core.contains("URLSession.shared"))
        XCTAssertTrue(adapter.contains("try Self.validate(networkRequest"))
        XCTAssertTrue(adapter.contains("delegate: DataEgressRedirectBlocker()"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        XCTAssertTrue(byok.contains("gateway.perform(networkRequest, metadata: metadata)"))
        let clientStart = try XCTUnwrap(
            byok.range(of: "public struct CompanionBYOKClient"))
        let settingsStart = try XCTUnwrap(byok.range(
            of: "public enum BYOKSettings",
            range: clientStart.upperBound..<byok.endIndex))
        let companionClient = byok[clientStart.lowerBound..<settingsStart.lowerBound]
        XCTAssertFalse(companionClient.contains("URLSession"))
        XCTAssertFalse(companionClient.contains("data(for:"))
        XCTAssertTrue(companion.contains("completeCompanionQuestion"))
        XCTAssertFalse(companion.contains("byok.complete("))
        XCTAssertFalse(companion.contains("OpenAICompatibleSummaryClient("))
        XCTAssertFalse(companion.contains("session.data(for:"))
        XCTAssertFalse(provenance.contains("session.data(for:"))
        XCTAssertTrue(provenance.contains(
            "egressConsentSource: DataEgressConsentSource = .explicitCompanionClient"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(recording.contains("await services.companionBYOKClient()"))
        XCTAssertTrue(refresh.contains("byok: CompanionBYOKClient?"))
        XCTAssertTrue(appApplication.contains("BYOKSettings.companionClient("))
        XCTAssertTrue(appApplication.contains("apiKey: try? await secrets.value"))
        XCTAssertFalse(byok.contains("SecretStore"))
        for source in [recording, refresh] {
            XCTAssertTrue(source.contains(
                "egressConsentSource: .companionBYOKSettings"))
            XCTAssertFalse(source.contains("URLSession.shared"))
            XCTAssertFalse(source.contains("data(for:"))
        }
    }

    func testExplicitCorrectedCompanionRefreshKeepsEvidenceAndPublicationFenced() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/RegenerateCompanionCards.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Companion.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CompanionRegeneration.swift")
        let rail = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailRailSection.swift")
        let correction = try Self.contents(
            of: "Sources/ApplicationKit/CorrectMeetingTranscript.swift")
            + Self.contents(
                of: "Sources/ApplicationKit/RestructureMeetingTranscript.swift")
        let uiTests = try Self.contents(
            of: "Tests/PortavozUITests/MeetingDetailUITests.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains("struct RegenerateCompanionCards"))
        XCTAssertTrue(workflow.contains("MeetingTranscriptGenerationMaterial"))
        XCTAssertTrue(workflow.contains(
            "guard pass.completed, pass.terminalRuns.isEmpty else { return .preserved }"))
        XCTAssertTrue(workflow.contains("replaceRegeneratedCompanionCards"))
        XCTAssertFalse(workflow.contains("import SwiftUI"))
        XCTAssertTrue(provenance.contains("case meetingReview = \"meeting-review\""))
        XCTAssertTrue(provenance.contains("companion-generation-v3"))
        XCTAssertTrue(provenance.contains("evidenceSourceIDsByGeneratedID"))
        XCTAssertTrue(provenance.contains("evidence-source-count:"))
        XCTAssertTrue(storage.contains("func replaceReviewedCompanionCards("))
        XCTAssertTrue(storage.contains(
            "reviewed Companion cards require immutable question evidence"))
        XCTAssertTrue(storage.contains("func saveReviewedCompanionGenerationRun("))
        XCTAssertTrue(storage.contains("workflow: \"meeting-review\""))
        XCTAssertFalse(storage.contains("workflow: String ="))
        XCTAssertFalse(storage.contains("public func saveCompanionGenerationRun("))
        XCTAssertTrue(storage.contains("sourceCorrectionRevision: correctionRevision"))
        XCTAssertTrue(adapter.contains("services.usesTemporaryMeetingStore"))
        XCTAssertTrue(adapter.contains("-simulate-apuntador-refresh-success"))
        XCTAssertTrue(adapter.contains("workflow: .meetingReview"))
        XCTAssertTrue(rail.contains("detail-apuntador-refresh"))
        XCTAssertTrue(uiTests.contains("testExplicitApuntadorRefreshUsesCorrectedTranscript"))
        XCTAssertFalse(correction.contains("RegenerateCompanionCards"))
        XCTAssertTrue(decisions.contains("## D331"))
    }

    func testOpenAICompatibleSummaryEgressCannotBypassTheGateway() throws {
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let ollama = try Self.contents(of: "Sources/IntelligenceKit/OllamaService.swift")
        let regeneration = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")
        let processing = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLISummarize.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-cli/CLIComposition.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/AnalyzeAudioFile.swift")

        XCTAssertTrue(byok.contains("public struct OpenAICompatibleSummaryClient"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        let summaryStart = try XCTUnwrap(
            byok.range(of: "public struct OpenAICompatibleSummaryClient"))
        let companionStart = try XCTUnwrap(byok.range(
            of: "struct CompanionDataEgressContext",
            range: summaryStart.upperBound..<byok.endIndex))
        let summaryClient = byok[summaryStart.lowerBound..<companionStart.lowerBound]
        XCTAssertTrue(summaryClient.contains("gateway.perform(networkRequest, metadata: metadata)"))
        XCTAssertFalse(summaryClient.contains("URLSession"))
        XCTAssertFalse(summaryClient.contains("data(for:"))
        XCTAssertTrue(provider.contains("client.completeSummary("))
        XCTAssertFalse(provider.contains("URLSession"))
        XCTAssertFalse(provider.contains("data(for:"))
        XCTAssertTrue(ollama.contains("gateway: any DataEgressGateway"))

        XCTAssertTrue(regeneration.contains("gateway: gateway"))
        XCTAssertTrue(regeneration.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(processing.contains("gateway: dataEgressGateway"))
        XCTAssertTrue(processing.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(cli.contains("platform.summarizeAudio("))
        XCTAssertFalse(cli.contains("application?.store"))
        XCTAssertFalse(cli.contains("OpenAICompatibleSummaryProvider("))
        XCTAssertTrue(composition.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        let admittedMeeting = try XCTUnwrap(workflow.range(
            of: "try await store.saveAnalyzedMeeting("))
        let remoteSummary = try XCTUnwrap(workflow.range(
            of: "let draft = try await processor.summarize(summaryRequest)"))
        XCTAssertLessThan(admittedMeeting.lowerBound, remoteSummary.lowerBound)
        XCTAssertFalse(cli.contains("URLSession.shared"))
        XCTAssertFalse(cli.contains("data(for:"))
    }

    func testExplicitPublishingEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let gist = try Self.contents(of: "Sources/IntegrationsKit/GistPublisher.swift")
        let issues = try Self.contents(of: "Sources/IntegrationsKit/IssueExporters.swift")
        let detail = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift")
        let appDocuments = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDocuments.swift")
        let applicationDocuments = try Self.contents(
            of: "Sources/ApplicationKit/PublishMeetingContent.swift")
        let cliExport = try Self.contents(of: "Sources/portavoz-cli/CLIExport.swift")
        let cliIssues = try Self.contents(of: "Sources/portavoz-cli/CLIIssues.swift")
        let cliComposition = try Self.contents(
            of: "Sources/portavoz-cli/CLIComposition.swift")
        let cliAdapters = try Self.contents(
            of: "Sources/portavoz-cli/CLIProductAdapters.swift")

        for operation in ["publishGitHubGist", "createGitHubIssue", "createLinearIssue"] {
            XCTAssertTrue(core.contains(operation))
            XCTAssertTrue(adapter.contains("case .\(operation):"))
        }
        for publisher in [gist, issues] {
            XCTAssertTrue(publisher.contains("private let gateway: any DataEgressGateway"))
            XCTAssertTrue(publisher.contains("gateway.perform("))
            XCTAssertFalse(publisher.contains("URLSession"))
            XCTAssertFalse(publisher.contains("data(for:"))
        }
        XCTAssertTrue(detail.contains("model.send(.publishGist("))
        XCTAssertTrue(detail.contains("model.send(.prepareDocument("))
        XCTAssertFalse(detail.contains("services.publishMeetingDetailGist("))
        XCTAssertFalse(detail.contains("services.prepareMeetingDetailDocument("))
        XCTAssertFalse(detail.contains("GistPublisher("))
        XCTAssertFalse(detail.contains("MeetingExporter.markdown("))
        XCTAssertFalse(detail.contains("gateway: services.dataEgressGateway"))
        XCTAssertTrue(appDocuments.contains("PrepareMeetingDocument("))
        XCTAssertTrue(appDocuments.contains("ExportMeetingDocument("))
        XCTAssertTrue(appDocuments.contains("GistPublisher(token: token, gateway: gateway)"))
        XCTAssertTrue(applicationDocuments.contains("struct PrepareMeetingDocument"))
        XCTAssertTrue(cliExport.contains("application.exportMeetingDocument("))
        XCTAssertTrue(cliExport.contains("meetingID: meetingID"))
        XCTAssertTrue(cliExport.contains("md|pdf|srt|vtt"))
        XCTAssertTrue(cliExport.contains("MeetingDocumentFormat("))
        XCTAssertTrue(cliExport.contains("fileExtension: gist ? \"md\" : format"))
        XCTAssertTrue(cliIssues.contains("application.publishMeetingActionItems("))
        XCTAssertTrue(cliIssues.contains("meetingID: meetingID"))
        XCTAssertTrue(cliComposition.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(cliAdapters.contains("meetingID: meetingID"))
        for source in [cliExport, cliIssues] {
            XCTAssertFalse(source.contains("GistPublisher("))
            XCTAssertFalse(source.contains("GitHubIssuesExporter("))
            XCTAssertFalse(source.contains("LinearExporter("))
        }
    }

    func testMeetingContentEgressPersistsReceiptBeforeTransport() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+PrivacyReceipt.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressEventRecorder"))
        XCTAssertTrue(core.contains("public struct PrivacyReceipt"))
        let validation = try XCTUnwrap(adapter.range(of: "try Self.validate(networkRequest"))
        let receipt = try XCTUnwrap(adapter.range(of: "recordDataEgressEvent"))
        let transport = try XCTUnwrap(
            adapter.range(of: "let (bytes, response) = try await session.bytes("))
        XCTAssertLessThan(validation.lowerBound, receipt.lowerBound)
        XCTAssertLessThan(receipt.lowerBound, transport.lowerBound)
        XCTAssertTrue(storage.contains("extension MeetingStore: DataEgressEventRecorder"))
        XCTAssertTrue(storage.contains("guard let meetingID = event.meetingID"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))

        let forbiddenReceiptFields = [
            "transcript", "prompt", "markdown", "question", "answer", "actionItemText",
        ]
        let eventStart = try XCTUnwrap(core.range(of: "public struct DataEgressEvent"))
        let recorderStart = try XCTUnwrap(core.range(
            of: "public protocol DataEgressEventRecorder",
            range: eventStart.upperBound..<core.endIndex))
        let eventSource = core[eventStart.lowerBound..<recorderStart.lowerBound]
        for field in forbiddenReceiptFields {
            XCTAssertFalse(eventSource.contains("public let \(field)"), field)
        }
    }

    func testCompanionEvidenceStaysRoleTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/CompanionCard.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CompanionCardEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CompanionCardEvidence.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let detail = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailRailSection.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct CompanionCardEvidence"))
        XCTAssertTrue(core.contains("questionSegmentIDs"))
        XCTAssertTrue(core.contains("answerSegmentIDs"))
        XCTAssertTrue(schema.contains("table: \"companionCardEvidence\""))
        XCTAssertTrue(schema.contains("role IN ('question', 'answer')"))
        XCTAssertTrue(storage.contains("Companion evidence is stale"))
        XCTAssertTrue(schema.contains("onDelete: .setNull"))
        XCTAssertTrue(provenance.contains("CompanionEvidenceFactory"))
        XCTAssertTrue(provenance.contains("questionSegmentIDs"))
        XCTAssertTrue(companion.contains("citedPassageIndexes"))
        XCTAssertTrue(bundle.contains("remappedCompanionCard"))
        XCTAssertTrue(detail.contains("Question source"))
        XCTAssertTrue(detail.contains("Answer sources"))
        XCTAssertFalse(diagnostics.contains("CompanionCardEvidence"))
    }
}
