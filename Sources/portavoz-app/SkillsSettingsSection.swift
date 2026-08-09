import ApplicationKit
import PortavozCore
import SwiftUI

/// D317 — the Phase-2 Skills control plane. It projects the real catalogue,
/// durable policy, and a bounded content-free receipt history; this view never
/// executes a skill or invents an external consent rule.
struct SkillsSettingsSection: View {
    @Environment(AppServices.self) private var services

    @State private var snapshot: SkillControlCenterSnapshot?
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var loadFailed = false

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

                Section("Coming later") {
                    ForEach(plannedSkills) { skill in
                        plannedSkillRow(skill)
                    }
                }

                Section("Recent receipts") {
                    receiptContent
                }
            }
        }
        .task {
            await load()
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
        } else if loadFailed, snapshot == nil {
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
                .disabled(snapshot == nil || isLoading || isMutating)
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
            if loadFailed {
                Label(
                    "The last change could not be verified. Close and reopen Settings before trying again.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-skills-stale-error")
            }
        }
    }

    @ViewBuilder
    private var receiptContent: some View {
        if let receipts = snapshot?.receipts, receipts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No skill runs yet", systemImage: "checkmark.seal")
                Text("A receipt appears here only after you confirm a skill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-skills-empty-receipts")
        } else {
            ForEach(snapshot?.receipts ?? []) { receipt in
                receiptRow(receipt)
            }
            Text("Shows the 20 most recent runs on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: skillBinding(skill))
                .labelsHidden()
                .accessibilityLabel(skillTitle(skill.id))
                .accessibilityIdentifier(
                    "settings-skill-\(skill.id)-enabled")
                .disabled(isLoading || isMutating || loadFailed)
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

    private func receiptRow(
        _ receipt: SkillControlCenterReceipt
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: receiptIcon(receipt.state))
                .foregroundStyle(receiptTint(receipt.state))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(skillTitle(receipt.skillID))
                    .font(.callout.weight(.medium))
                Text(receiptStatus(receipt.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(receipt.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "settings-skill-receipt-\(receipt.skillID)")
    }

    @MainActor
    private func load() async {
        guard !isLoading, !isMutating else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await services.loadSkillControlCenter()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    @MainActor
    private func mutate(_ action: ManageSkillControlAction) async {
        guard snapshot != nil, !loadFailed, !isLoading, !isMutating else {
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            guard try await services.manageSkillControl(action) == .updated
            else {
                loadFailed = true
                return
            }
            snapshot = try await services.loadSkillControlCenter()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func skillTitle(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id: L10n.text("Recap draft")
        case MeetingPackageExportSkill.id: L10n.text("Text-only meeting package")
        case ReminderDraftSkill.id: L10n.text("Reminder draft")
        case PreMeetingBriefSkill.id: L10n.text("Pre-meeting brief")
        default: L10n.text("Unknown skill")
        }
    }

    private func skillDescription(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id:
            L10n.text("Prepares the exact recap for your clipboard after confirmation.")
        case MeetingPackageExportSkill.id:
            L10n.text("Writes a text-only package to the destination you approve.")
        case ReminderDraftSkill.id:
            L10n.text("Will prepare a local reminder after its calendar permission flow ships.")
        case PreMeetingBriefSkill.id:
            L10n.text("Will propose a cited brief from the upcoming calendar event.")
        default:
            L10n.text("No description is available.")
        }
    }

    private func iconName(_ skillID: String) -> String {
        switch skillID {
        case RecapDraftSkill.id: "doc.on.clipboard"
        case MeetingPackageExportSkill.id: "shippingbox"
        case ReminderDraftSkill.id: "checklist"
        case PreMeetingBriefSkill.id: "calendar.badge.clock"
        default: "sparkles"
        }
    }

    private func receiptStatus(_ state: SkillExecutionState) -> String {
        switch state {
        case .proposed: L10n.text("Proposed — nothing ran")
        case .previewed: L10n.text("Previewed — nothing ran")
        case .confirmed: L10n.text("Confirmed — waiting")
        case .executing: L10n.text("Needs review after interruption")
        case .succeeded: L10n.text("Succeeded")
        case .failed: L10n.text("Failed — retry is available")
        case .dismissed: L10n.text("Cancelled — nothing ran")
        }
    }

    private func receiptIcon(_ state: SkillExecutionState) -> String {
        switch state {
        case .succeeded: "checkmark.circle.fill"
        case .failed, .executing: "exclamationmark.triangle.fill"
        case .dismissed: "xmark.circle"
        case .proposed, .previewed, .confirmed: "clock"
        }
    }

    private func receiptTint(_ state: SkillExecutionState) -> Color {
        switch state {
        case .succeeded: .green
        case .failed, .executing: .orange
        case .dismissed, .proposed, .previewed, .confirmed: .secondary
        }
    }
}
