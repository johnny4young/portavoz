import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingDetailActivityValues {
    let privacyReceipt: PrivacyReceipt?
    let skillReceipts: [MeetingSkillReceipt]
    let presentation: MeetingDetailPresentation

    var hasContent: Bool { privacyReceipt != nil || !skillReceipts.isEmpty }
}

/// One line under the meeting title: what Portavoz did on the user's behalf
/// here and whether any content left this Mac. The chip states the outcome;
/// the popover carries the auditable detail (remote attempts, private iCloud
/// copy, every confirmed action) without taking rail space.
struct MeetingDetailActivityLine: View {
    let values: MeetingDetailActivityValues

    @State private var showsActivity = false

    var body: some View {
        if values.hasContent {
            Button {
                showsActivity.toggle()
            } label: {
                Label(chipTitle, systemImage: chipSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(chipTint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chipTitle)
            .accessibilityIdentifier("detail-privacy-receipt")
            .help(L10n.text("See what left this Mac and every action you confirmed"))
            .popover(isPresented: $showsActivity, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        privacyReceiptSection
                        skillReceiptSection
                    }
                    .padding(16)
                }
                .frame(width: 340)
                .frame(maxHeight: 420)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail-activity-popover")
            }
        }
    }

    private var chipTitle: String {
        if let receipt = values.privacyReceipt {
            return privacyReceiptHeadline(receipt)
        }
        return L10n.text("Action history")
    }

    private var chipSymbol: String {
        values.privacyReceipt.map { privacyReceiptIcon($0.status) } ?? PVSymbol.history
    }

    private var chipTint: Color {
        values.privacyReceipt.map { privacyReceiptTint($0.status) } ?? .secondary
    }

    /// Q12/D316: every durable skill execution for this meeting — the
    /// auditable answer to "what did Portavoz do on my behalf here".
    @ViewBuilder
    private var skillReceiptSection: some View {
        if !values.skillReceipts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Action history")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(values.skillReceipts) { receipt in
                    HStack(spacing: 6) {
                        Image(systemName: receipt.state == .succeeded
                            ? PVSymbol.success
                            : PVSymbol.warning)
                            .foregroundStyle(
                                receipt.state == .succeeded ? .green : .orange)
                        Text(skillReceiptTitle(receipt))
                            .font(.caption)
                        Spacer(minLength: 4)
                        Text(receipt.updatedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // One element, explicit label: the row announces skill and
                    // outcome instead of an unreachable icon+text container.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(skillReceiptTitle(receipt))
                    .accessibilityIdentifier("skill-receipt-\(receipt.skillID)")
                }
            }
        }
    }

    private func skillReceiptTitle(_ receipt: MeetingSkillReceipt) -> String {
        if let external = SkillReceiptPresentation.meetingDetailTitle(
            skillID: receipt.skillID,
            state: receipt.state
        ) {
            return external
        }
        let name = switch receipt.skillID {
        case "recap-draft": L10n.text("Recap draft")
        case "meeting-package-export": L10n.text("Package export")
        default: receipt.skillID
        }
        return receipt.state == .succeeded
            ? L10n.format("%@ — completed", name)
            : L10n.format("%@ — did not finish", name)
    }

    @ViewBuilder
    private var privacyReceiptSection: some View {
        if let receipt = values.privacyReceipt {
            let tint = privacyReceiptTint(receipt.status)
            VStack(alignment: .leading, spacing: 8) {
                Label("Activity", systemImage: privacyReceiptIcon(receipt.status))
                    .font(.headline)
                    .foregroundStyle(tint)
                    .accessibilityIdentifier("detail-privacy-receipt")
                Text(privacyReceiptHeadline(receipt))
                    .font(.callout.weight(.semibold))
                Text(privacyReceiptExplanation(receipt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                privacyReceiptSyncLine(receipt.syncDisclosure)

                ForEach(Array(receipt.remoteEvents.enumerated()), id: \.element.id) { index, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(privacyReceiptOperation(event.operation))
                            .font(.caption.weight(.semibold))
                        Text(event.destinationHost)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(values.presentation.shortDate(event.attemptedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("privacy-remote-event-\(index)")
                }

                if !receipt.generation.isEmpty || !receipt.localDeviceEvents.isEmpty {
                    Text(L10n.format(
                        "Model activity: %d · Local transfers: %d",
                        receipt.generation.count,
                        receipt.localDeviceEvents.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func privacyReceiptSyncLine(_ disclosure: PrivacyReceiptSyncDisclosure) -> some View {
        if disclosure == .acknowledgedByPrivateCloud {
            VStack(alignment: .leading, spacing: 2) {
                Label(L10n.text("Synced to private iCloud"), systemImage: "icloud.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(L10n.text(
                    "This meeting's text was stored in encrypted fields in your private iCloud database."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("Synced to private iCloud"))
            .accessibilityValue(L10n.text(
                "This meeting's text was stored in encrypted fields in your private iCloud database."))
            .accessibilityIdentifier("detail-privacy-receipt-sync")
        }
    }

    private func privacyReceiptTint(_ status: PrivacyReceiptStatus) -> Color {
        switch status {
        case .allContentStayedOnDevice: .green
        case .noRemoteTransferRecorded: .orange
        case .remoteTransferAttempted: .orange
        }
    }

    private func privacyReceiptIcon(_ status: PrivacyReceiptStatus) -> String {
        switch status {
        case .allContentStayedOnDevice: PVSymbol.privacy
        case .noRemoteTransferRecorded: "clock.badge.questionmark"
        case .remoteTransferAttempted: "arrow.up.right.square.fill"
        }
    }

    private func privacyReceiptHeadline(_ receipt: PrivacyReceipt) -> String {
        switch receipt.status {
        case .allContentStayedOnDevice:
            if receipt.syncDisclosure == .acknowledgedByPrivateCloud {
                L10n.text("No third-party service used")
            } else {
                L10n.text("No remote service used")
            }
        case .noRemoteTransferRecorded:
            L10n.text("No remote transfer recorded")
        case .remoteTransferAttempted:
            L10n.text("Remote transfer attempted")
        }
    }

    private func privacyReceiptExplanation(_ receipt: PrivacyReceipt) -> String {
        switch receipt.status {
        case .allContentStayedOnDevice:
            return L10n.text("All tracked meeting processing stayed on this Mac.")
        case .noRemoteTransferRecorded:
            return L10n.format(
                "Tracking began %@; earlier activity is not covered.",
                values.presentation.shortDate(receipt.trackingStartedAt))
        case .remoteTransferAttempted:
            if receipt.remoteEvents.count == 1 {
                return L10n.text(
                    "1 remote transfer attempt was recorded. Content may have left this Mac.")
            }
            return L10n.format(
                "%d remote transfer attempts were recorded. Content may have left this Mac.",
                receipt.remoteEvents.count)
        }
    }

    private func privacyReceiptOperation(_ operation: DataEgressOperation) -> String {
        switch operation {
        case .companionKnowledgeAnswer: L10n.text("Apuntador question only")
        case .askAnswerGeneration: L10n.text("Ask answer material")
        case .webSourceRetrieval: L10n.text("Web source request")
        case .summaryGeneration: L10n.text("Summary material")
        case .publishGitHubGist: L10n.text("Meeting export")
        case .createGitHubIssue: L10n.text("GitHub action item")
        case .createLinearIssue: L10n.text("Linear action item")
        }
    }
}
