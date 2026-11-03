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
    @State private var controlChange = SkillActionAttempt<SkillControlsSubject>()
    @State private var receiptScopeLoadFailed = false
    @State private var receiptQuery = SkillActivityQuery()
    @State private var activeLoadID: UUID?
    @State private var proposalSnapshot: SkillOfferReviewSnapshot?
    @State private var proposalsAreLoading = false
    @State private var proposalLoadFailed = false
    @State private var activeProposalLoadID: UUID?
    @State private var proposalReview = SkillActionAttempt<UUID>()
    @State private var proposalDismissal = SkillActionAttempt<UUID>()
    @State private var standingPolicyRevision = 0
    @State private var standingMutationInFlight = false

    var body: some View {
        Group {
            Section("Control") {
                Text(
                    // Keep this as one literal so localization validation sees it.
                    "Portavoz suggests actions from your meetings. Nothing runs until you confirm it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-actions-explanation")
                controlContent
            }

            if snapshot != nil {
                StandingSkillRulesSection(
                    policyRevision: standingPolicyRevision,
                    externalMutationInFlight: $standingMutationInFlight,
                    didChangeExecutionAuthority: {
                        Task { await load() }
                    })

                Section("Available actions") {
                    ForEach(availableSkills) { skill in
                        availableSkillRow(skill)
                    }
                }

                Section("Suggestions to review") {
                    SkillProposalSection(
                        snapshot: proposalSnapshot,
                        isLoading: proposalsAreLoading,
                        isMutating: isMutating || auxiliaryMutationInFlight,
                        loadFailed: proposalLoadFailed,
                        reviewingOfferID: proposalReview.inFlight,
                        reviewFailedOfferID: proposalReview.failed,
                        dismissingOfferID: proposalDismissal.inFlight,
                        dismissalFailedOfferID: proposalDismissal.failed,
                        review: { offer in
                            Task { await reviewProposal(offer) }
                        },
                        dismiss: { offer in
                            Task { await dismissProposal(offer) }
                        },
                        retry: { Task { await loadProposals() } },
                        refresh: { Task { await refreshProposals() } })
                }

                Section("Action history") {
                    SkillActivitySection(
                        receiptScope: $receiptQuery.selection.scope,
                        receiptSkillID: $receiptQuery.selection.skillID,
                        receiptPeriod: $receiptQuery.selection.period,
                        snapshot: snapshot,
                        skills: snapshot?.skills ?? [],
                        isLoading: isLoading || isMutating
                            || standingMutationInFlight,
                        isMutating: isMutating || auxiliaryMutationInFlight,
                        loadFailed: receiptScopeLoadFailed,
                        focusRequestID: receiptFocusRequestID,
                        historyWindow: receiptQuery.window,
                        retry: { Task { await load() } },
                        refresh: { Task { await refreshActivity() } },
                        clearFilters: clearActivityFilters,
                        showMore: { Task { await showMoreReceipts() } },
                        inspectReceipt: inspectReceipt)
                }
            }
        }
        .task(id: receiptQuery.selection) {
            await load()
        }
        .task {
            await loadProposals()
        }
        .onChange(of: activityRevision) {
            Task { await load() }
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
                Text(lastRunText(skill))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("settings-skill-\(skill.id)-last-run")
            }
            Spacer(minLength: 12)
            Toggle("", isOn: skillBinding(skill))
                .labelsHidden()
                .accessibilityLabel(skillTitle(skill.id))
                .accessibilityIdentifier(
                    "settings-skill-\(skill.id)-enabled")
                .disabled(controlsAreLocked)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// Reads the verified per-action map, never the filtered history page:
    /// an unavailable read says so instead of claiming "never".
    private func lastRunText(_ skill: SkillControlCenterItem) -> String {
        guard let snapshot, snapshot.lastRunLoadState == .verified else {
            return L10n.text("Last run unavailable")
        }
        guard let run = snapshot.lastRuns[skill.id] else { return L10n.text("Never run") }
        let when = run.updatedAt.formatted(.relative(presentation: .named))
        return run.state == .succeeded
            ? L10n.format("Last run %@", when)
            : L10n.format("Last run %@ · did not finish", when)
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
                    systemImage: PVSymbol.privacy)
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
        guard !isMutating, !auxiliaryMutationInFlight else { return }
        let requestedScope = receiptScope
        let requestedSkillID = receiptSkillID
        let requestedPeriod = receiptPeriod
        let requestedLimit = receiptQuery.window.requestedLimit
        let loadID = UUID()
        activeLoadID = loadID
        if snapshot?.receiptScope != requestedScope
            || snapshot?.receiptSkillID != requestedSkillID
            || snapshot?.receiptPeriod != requestedPeriod {
            receiptScopeLoadFailed = false
        }
        isLoading = true
        do {
            let loaded = try await services.loadSkillControlCenter(
                receiptScope: requestedScope,
                receiptSkillID: requestedSkillID,
                receiptPeriod: requestedPeriod,
                receiptLimit: requestedLimit)
            guard !Task.isCancelled else {
                finishLoad(loadID)
                return
            }
            guard activeLoadID == loadID,
                  receiptScope == requestedScope,
                  receiptSkillID == requestedSkillID,
                  receiptPeriod == requestedPeriod,
                  receiptQuery.window.requestedLimit == requestedLimit
            else {
                return
            }
            adopt(loaded)
            finishLoad(loadID)
        } catch is CancellationError {
            finishLoad(loadID)
        } catch {
            guard activeLoadID == loadID,
                  receiptScope == requestedScope,
                  receiptSkillID == requestedSkillID,
                  receiptPeriod == requestedPeriod,
                  receiptQuery.window.requestedLimit == requestedLimit
            else {
                return
            }
            controlChange.recordFailure(.controls)
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
        controlChange.clearFailure()
        receiptScopeLoadFailed = loaded.receiptLoadState == .unavailable
    }

    @MainActor
    private func mutate(_ action: ManageSkillControlAction) async {
        guard snapshot != nil,
              !controlLoadFailed,
              !isMutating,
              !auxiliaryMutationInFlight
        else {
            return
        }
        invalidateActiveLoad()
        controlChange.begin(.controls)
        defer { controlChange.finish(.controls) }
        do {
            guard try await services.manageSkillControl(action) == .updated
            else {
                controlChange.fail(.controls)
                return
            }
            let loaded = try await services.loadSkillControlCenter(
                receiptScope: receiptScope,
                receiptSkillID: receiptSkillID,
                receiptPeriod: receiptPeriod,
                receiptLimit: receiptQuery.window.requestedLimit)
            adopt(loaded)
            standingPolicyRevision &+= 1
            await loadProposals()
        } catch {
            controlChange.fail(.controls)
        }
    }

    @MainActor
    private func showMoreReceipts() async {
        guard let snapshot,
              snapshot.receiptScope == receiptScope,
              snapshot.receiptSkillID == receiptSkillID,
              snapshot.receiptPeriod == receiptPeriod,
              snapshot.receiptLoadState == .verified,
              receiptQuery.window.canExpand(
                  hasMoreReceipts: snapshot.hasMoreReceipts),
              !isLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }
        receiptQuery.window.expand()
        await load()
    }

    @MainActor
    private func refreshActivity() async {
        guard let snapshot,
              snapshot.receiptScope == receiptScope,
              snapshot.receiptSkillID == receiptSkillID,
              snapshot.receiptPeriod == receiptPeriod,
              snapshot.receiptLoadState == .verified,
              !isLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }
        await load()
    }

    @MainActor
    private func clearActivityFilters() {
        guard let snapshot,
              snapshot.receiptScope == receiptScope,
              snapshot.receiptSkillID == receiptSkillID,
              snapshot.receiptPeriod == receiptPeriod,
              snapshot.receiptLoadState == .verified,
              snapshot.receipts.isEmpty,
              receiptSkillID != nil || receiptPeriod != .anytime,
              !isLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }
        receiptQuery.selection.skillID = nil
        receiptQuery.selection.period = .anytime
    }

}

private extension SkillsSettingsSection {
    @MainActor
    func loadProposals() async {
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
            let offerExists = { (id: UUID) in loaded.offers.contains { $0.id == id } }
            proposalDismissal.keepFailure(where: offerExists)
            proposalReview.keepFailure(where: offerExists)
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
    func finishProposalLoad(_ loadID: UUID) {
        guard activeProposalLoadID == loadID else { return }
        activeProposalLoadID = nil
        proposalsAreLoading = false
    }

    @MainActor
    func refreshProposals() async {
        guard proposalSnapshot != nil,
              !proposalLoadFailed,
              !proposalsAreLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }
        await loadProposals()
    }

    @MainActor
    func dismissProposal(_ offer: SkillOfferReviewItem) async {
        guard proposalSnapshot?.offers.contains(where: { $0.id == offer.id }) == true,
              !proposalsAreLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }

        proposalReview.clearFailure()
        proposalDismissal.begin(offer.id)
        defer { proposalDismissal.finish(offer.id) }
        do {
            let outcome = try await services.dismissSkillOfferReview(offer.id)
            guard !Task.isCancelled, proposalDismissal.isInFlight(offer.id) else {
                return
            }
            switch outcome {
            case .dismissed, .unavailable:
                await loadProposals()
            }
        } catch is CancellationError {
            return
        } catch {
            proposalDismissal.fail(offer.id)
        }
    }

}

private extension SkillsSettingsSection {
    var receiptScope: SkillExecutionReviewScope { receiptQuery.selection.scope }
    var receiptSkillID: String? { receiptQuery.selection.skillID }
    var receiptPeriod: SkillExecutionReviewPeriod { receiptQuery.selection.period }
    var isMutating: Bool { controlChange.isInFlight }
    var controlLoadFailed: Bool { controlChange.hasFailed }

    var controlsAreLocked: Bool {
        skillControlsAreLocked(
            hasSnapshot: snapshot != nil,
            isChanging: isMutating || auxiliaryMutationInFlight,
            hasUnverifiedChange: controlLoadFailed)
    }

    @ViewBuilder
    var controlContent: some View {
        if isLoading, snapshot == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading actions…")
            }
            .accessibilityIdentifier("settings-skills-loading")
        } else if controlLoadFailed, snapshot == nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("Action controls are unavailable", systemImage: PVSymbol.warning)
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
            Toggle("Pause all actions", isOn: pauseBinding)
                .accessibilityLabel("Pause all actions")
                .accessibilityIdentifier("settings-skills-pause-all")
                .disabled(controlsAreLocked)
            Text(
                // Keep this as one literal so localization validation sees it.
                // swiftlint:disable:next line_length
                "Paused actions are no longer suggested and are blocked again immediately before they run. Your individual choices stay saved."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if snapshot?.isPaused == true {
                Label("All actions are paused", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-skills-paused-status")
            }
            if controlLoadFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "The last change could not be verified. Reload controls before trying again.",
                        systemImage: PVSymbol.warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings-skills-stale-error")
                    Button("Reload controls") {
                        Task { await load() }
                    }
                    .accessibilityIdentifier("settings-skills-stale-retry")
                    .disabled(
                        isLoading || isMutating || auxiliaryMutationInFlight)
                }
            }
        }
    }

    var proposalMutationInFlight: Bool {
        proposalReview.isInFlight || proposalDismissal.isInFlight
    }

    var auxiliaryMutationInFlight: Bool {
        proposalMutationInFlight || standingMutationInFlight
    }

    @MainActor
    func reviewProposal(_ offer: SkillOfferReviewItem) async {
        guard offer.reason != .upcomingCalendarEvent,
              proposalSnapshot?.offers.contains(where: { $0.id == offer.id }) == true,
              !proposalsAreLoading,
              !isMutating,
              !auxiliaryMutationInFlight
        else { return }

        proposalDismissal.clearFailure()
        proposalReview.begin(offer.id)
        defer { proposalReview.finish(offer.id) }
        do {
            let outcome = try await services.resolveSkillOfferReviewDestination(
                offer.id)
            guard !Task.isCancelled, proposalReview.isInFlight(offer.id) else {
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
            proposalReview.fail(offer.id)
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
        case GitHubIssueCreateSkill.id:
            L10n.text(
                // Keep this as one literal so localization validation sees it.
                // swiftlint:disable:next line_length
                "Creates one cited GitHub issue from a pending action item after you review the repository and exact body.")
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
        case GitHubIssueCreateSkill.id: "ladybug"
        case MeetingPackageExportSkill.id: "shippingbox"
        case ReminderDraftSkill.id: "checklist"
        case PreMeetingBriefSkill.id: "calendar.badge.clock"
        default: PVSymbol.automations
        }
    }

}
