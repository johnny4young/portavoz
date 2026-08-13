import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// D317 — the Phase-2 Skills control plane. It projects the real catalogue,
/// durable policy, and a bounded content-free receipt history; this view never
/// executes a skill or invents an external consent rule.
struct SkillsSettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    let activityRevision: Int
    let receiptFocusRequestID: UUID?
    let inspectReceipt: (SkillControlCenterReceipt) -> Void

    @State private var snapshot: SkillControlCenterSnapshot?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var controlLoadFailed = false
    @State private var receiptScopeLoadFailed = false
    @State private var receiptScope: SkillExecutionReviewScope = .recent
    @State private var activeLoadID: UUID?
    @State private var proposalSnapshot: SkillOfferReviewSnapshot?
    @State private var proposalsAreLoading = false
    @State private var proposalLoadFailed = false
    @State private var activeProposalLoadID: UUID?
    @State private var reviewingProposalID: UUID?
    @State private var proposalReviewFailedID: UUID?
    @State private var dismissingProposalID: UUID?
    @State private var proposalDismissalFailedID: UUID?

    var body: some View {
        Group {
            Section("Control") {
                controlContent
            }

            if snapshot != nil {
                Section("Available now") {
                    ForEach(availableSkills) { skill in
                        availableSkillRow(skill)
                    }
                }

                if !plannedSkills.isEmpty {
                    Section("Coming later") {
                        ForEach(plannedSkills) { skill in
                            plannedSkillRow(skill)
                        }
                    }
                }

                Section("Proposed") {
                    SkillProposalSection(
                        snapshot: proposalSnapshot,
                        isLoading: proposalsAreLoading,
                        isMutating: isMutating || proposalMutationInFlight,
                        loadFailed: proposalLoadFailed,
                        reviewingOfferID: reviewingProposalID,
                        reviewFailedOfferID: proposalReviewFailedID,
                        dismissingOfferID: dismissingProposalID,
                        dismissalFailedOfferID: proposalDismissalFailedID,
                        review: { offer in
                            Task { await reviewProposal(offer) }
                        },
                        dismiss: { offer in
                            Task { await dismissProposal(offer) }
                        },
                        retry: { Task { await loadProposals() } })
                }

                Section("Skill activity") {
                    SkillActivitySection(
                        receiptScope: $receiptScope,
                        snapshot: snapshot,
                        isLoading: isLoading || isMutating,
                        isMutating: isMutating || proposalMutationInFlight,
                        loadFailed: receiptScopeLoadFailed,
                        focusRequestID: receiptFocusRequestID,
                        retry: { Task { await load() } },
                        inspectReceipt: inspectReceipt)
                }
            }
        }
        .task(id: receiptScope) {
            await load()
        }
        .task {
            await loadProposals()
        }
        .onChange(of: activityRevision) {
            Task { await load() }
        }
    }

    @ViewBuilder
    private var controlContent: some View {
        if isLoading, snapshot == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading skills…")
            }
            .accessibilityIdentifier("settings-skills-loading")
        } else if controlLoadFailed, snapshot == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("Skill controls are unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-skills-load-error")
                Text("Nothing can be changed until Portavoz reads the durable policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await load() }
                }
                .accessibilityIdentifier("settings-skills-retry")
            }
        } else {
            Toggle("Pause all skills", isOn: pauseBinding)
                .accessibilityIdentifier("settings-skills-pause-all")
                .disabled(
                    snapshot == nil || isMutating
                        || proposalMutationInFlight || controlLoadFailed)
            Text(
                // Keep this as one literal so localization validation sees it.
                // swiftlint:disable:next line_length
                "Paused skills disappear from proposal surfaces and are refused again immediately before execution. Your individual choices stay saved."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if snapshot?.isPaused == true {
                Label("All skills are paused", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-skills-paused-status")
            }
            if controlLoadFailed {
                Label(
                    "The last change could not be verified. Close and reopen Settings before trying again.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-skills-stale-error")
            }
        }
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { snapshot?.isPaused ?? false },
            set: { isPaused in
                Task { await mutate(.setPaused(isPaused)) }
            })
    }

    private var availableSkills: [SkillControlCenterItem] {
        snapshot?.skills.filter { $0.availability == .available } ?? []
    }

    private var plannedSkills: [SkillControlCenterItem] {
        snapshot?.skills.filter { $0.availability == .planned } ?? []
    }

    private func availableSkillRow(
        _ skill: SkillControlCenterItem
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            skillIcon(skill)
            VStack(alignment: .leading, spacing: 3) {
                Text(skillTitle(skill.id))
                    .font(.callout.weight(.semibold))
                Text(skillDescription(skill.id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                skillDisclosure(skill)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: skillBinding(skill))
                .labelsHidden()
                .accessibilityLabel(skillTitle(skill.id))
                .accessibilityIdentifier(
                    "settings-skill-\(skill.id)-enabled")
                .disabled(
                    isMutating || proposalMutationInFlight
                        || controlLoadFailed)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func plannedSkillRow(
        _ skill: SkillControlCenterItem
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            skillIcon(skill)
            VStack(alignment: .leading, spacing: 3) {
                Text(skillTitle(skill.id))
                    .font(.callout.weight(.semibold))
                Text(skillDescription(skill.id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text("Planned")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-skill-\(skill.id)-planned")
    }

    private func skillIcon(_ skill: SkillControlCenterItem) -> some View {
        Image(systemName: iconName(skill.id))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PVDesign.accent)
            .frame(width: 30, height: 30)
            .background(PVDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private func skillDisclosure(
        _ skill: SkillControlCenterItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch skill.disclosureBoundary {
            case .noDirectNetworkHandoff:
                Label(
                    "No direct network handoff",
                    systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier(
                        "settings-skill-\(skill.id)-boundary")
                    .accessibilityLabel("No direct network handoff")
            case .externalHandoff:
                Label(
                    "May share outside Portavoz",
                    systemImage: "arrow.up.right.square.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "settings-skill-\(skill.id)-boundary")
                    .accessibilityLabel("May share outside Portavoz")
            }

            if skill.definition.confirmationPolicy == .explicitPerProposal {
                Label(
                    "Approval required every time",
                    systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "settings-skill-\(skill.id)-confirmation")
                    .accessibilityLabel("Approval required every time")
            }
        }
        .font(.caption2.weight(.medium))
    }

    private func skillBinding(
        _ skill: SkillControlCenterItem
    ) -> Binding<Bool> {
        Binding(
            get: {
                snapshot?.skills.first(where: { $0.id == skill.id })?
                    .isEnabled ?? false
            },
            set: { isEnabled in
                Task {
                    await mutate(.setSkillEnabled(
                        skillID: skill.id,
                        isEnabled: isEnabled))
                }
            })
    }

    @MainActor
    private func load() async {
        guard !isMutating, !proposalMutationInFlight else { return }
        let requestedScope = receiptScope
        let loadID = UUID()
        activeLoadID = loadID
        if snapshot?.receiptScope != requestedScope {
            receiptScopeLoadFailed = false
        }
        isLoading = true
        do {
            let loaded = try await services.loadSkillControlCenter(
                receiptScope: requestedScope)
            guard !Task.isCancelled else {
                finishLoad(loadID)
                return
            }
            guard activeLoadID == loadID, receiptScope == requestedScope else {
                return
            }
            adopt(loaded)
            finishLoad(loadID)
        } catch is CancellationError {
            finishLoad(loadID)
        } catch {
            guard activeLoadID == loadID, receiptScope == requestedScope else {
                return
            }
            controlLoadFailed = true
            receiptScopeLoadFailed = snapshot != nil
            finishLoad(loadID)
        }
    }

    @MainActor
    private func finishLoad(_ loadID: UUID) {
        guard activeLoadID == loadID else { return }
        activeLoadID = nil
        isLoading = false
    }

    @MainActor
    private func invalidateActiveLoad() {
        activeLoadID = nil
        isLoading = false
    }

    @MainActor
    private func adopt(_ loaded: SkillControlCenterSnapshot) {
        snapshot = loaded
        controlLoadFailed = false
        receiptScopeLoadFailed = loaded.receiptLoadState == .unavailable
    }

    @MainActor
    private func mutate(_ action: ManageSkillControlAction) async {
        guard snapshot != nil,
              !controlLoadFailed,
              !isMutating,
              !proposalMutationInFlight
        else {
            return
        }
        invalidateActiveLoad()
        isMutating = true
        defer { isMutating = false }
        do {
            guard try await services.manageSkillControl(action) == .updated
            else {
                controlLoadFailed = true
                return
            }
            let loaded = try await services.loadSkillControlCenter(
                receiptScope: receiptScope)
            adopt(loaded)
            await loadProposals()
        } catch {
            controlLoadFailed = true
        }
    }

    @MainActor
    private func loadProposals() async {
        let loadID = UUID()
        activeProposalLoadID = loadID
        proposalsAreLoading = true
        do {
            let loaded = try await services.loadSkillOfferReview()
            guard !Task.isCancelled else {
                finishProposalLoad(loadID)
                return
            }
            guard activeProposalLoadID == loadID else { return }
            proposalSnapshot = loaded
            if let failedID = proposalDismissalFailedID,
               !loaded.offers.contains(where: { $0.id == failedID }) {
                proposalDismissalFailedID = nil
            }
            if let failedID = proposalReviewFailedID,
               !loaded.offers.contains(where: { $0.id == failedID }) {
                proposalReviewFailedID = nil
            }
            proposalLoadFailed = false
            finishProposalLoad(loadID)
        } catch is CancellationError {
            finishProposalLoad(loadID)
        } catch {
            guard activeProposalLoadID == loadID else { return }
            proposalSnapshot = nil
            proposalLoadFailed = true
            finishProposalLoad(loadID)
        }
    }

    @MainActor
    private func finishProposalLoad(_ loadID: UUID) {
        guard activeProposalLoadID == loadID else { return }
        activeProposalLoadID = nil
        proposalsAreLoading = false
    }

    @MainActor
    private func dismissProposal(_ offer: SkillOfferReviewItem) async {
        guard proposalSnapshot?.offers.contains(where: { $0.id == offer.id }) == true,
              !proposalsAreLoading,
              !isMutating,
              !proposalMutationInFlight
        else { return }

        dismissingProposalID = offer.id
        proposalReviewFailedID = nil
        proposalDismissalFailedID = nil
        defer {
            if dismissingProposalID == offer.id {
                dismissingProposalID = nil
            }
        }
        do {
            let outcome = try await services.dismissSkillOfferReview(offer.id)
            guard !Task.isCancelled, dismissingProposalID == offer.id else {
                return
            }
            switch outcome {
            case .dismissed, .unavailable:
                await loadProposals()
            }
        } catch is CancellationError {
            return
        } catch {
            guard dismissingProposalID == offer.id else { return }
            proposalDismissalFailedID = offer.id
        }
    }

}

private extension SkillsSettingsSection {
    var proposalMutationInFlight: Bool {
        reviewingProposalID != nil || dismissingProposalID != nil
    }

    @MainActor
    func reviewProposal(_ offer: SkillOfferReviewItem) async {
        guard offer.reason != .upcomingCalendarEvent,
              proposalSnapshot?.offers.contains(where: { $0.id == offer.id }) == true,
              !proposalsAreLoading,
              !isMutating,
              !proposalMutationInFlight
        else { return }

        reviewingProposalID = offer.id
        proposalDismissalFailedID = nil
        proposalReviewFailedID = nil
        defer {
            if reviewingProposalID == offer.id {
                reviewingProposalID = nil
            }
        }
        do {
            let outcome = try await services.resolveSkillOfferReviewDestination(
                offer.id)
            guard !Task.isCancelled, reviewingProposalID == offer.id else {
                return
            }
            switch outcome {
            case .unavailable:
                await loadProposals()
            case .destination(let destination):
                openReviewDestination(destination)
            }
        } catch is CancellationError {
            return
        } catch {
            guard reviewingProposalID == offer.id else { return }
            proposalReviewFailedID = offer.id
        }
    }

    @MainActor
    func openReviewDestination(
        _ destination: SkillOfferReviewDestination
    ) {
        switch destination {
        case .meeting(let meetingID):
            services.pendingRoute = .meeting(meetingID)
        case .commitment(let commitmentID):
            services.pendingRoute = .commitments(.commitment(commitmentID))
        case .residentMenuBar:
            return
        }
        openWindow(id: "main", value: MainWindowIdentity.primary)
        dismissWindow()
    }

    private func skillTitle(_ skillID: String) -> String {
        SkillReceiptPresentation.skillTitle(skillID)
    }

    private func skillDescription(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id:
            L10n.text("Prepares the exact recap for your clipboard after confirmation.")
        case EmailRecapDraftSkill.id:
            L10n.text(
                "Opens the exact reviewed recap in your email app with no recipients. Portavoz never sends it.")
        case SecretGistPublishSkill.id:
            L10n.text(
                "Publishes the exact reviewed meeting document as one secret GitHub Gist. Every run asks first.")
        case MeetingPackageExportSkill.id:
            L10n.text("Writes a text-only package to the destination you approve.")
        case ReminderDraftSkill.id:
            L10n.text("Creates one local reminder from a confirmed commitment after you approve it.")
        case PreMeetingBriefSkill.id:
            L10n.text("Proposes an exact cited brief beside your next calendar event.")
        default:
            L10n.text("No description is available.")
        }
    }

    private func iconName(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id: "doc.on.clipboard"
        case EmailRecapDraftSkill.id: "envelope.open"
        case SecretGistPublishSkill.id: "chevron.left.forwardslash.chevron.right"
        case MeetingPackageExportSkill.id: "shippingbox"
        case ReminderDraftSkill.id: "checklist"
        case PreMeetingBriefSkill.id: "calendar.badge.clock"
        default: "sparkles"
        }
    }

}
