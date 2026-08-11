import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingDetailOperationStatus: View {
    let progress: String?
    let error: String?

    @ViewBuilder
    var body: some View {
        if let progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).foregroundStyle(.secondary)
            }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}

struct MeetingDetailTrustValues {
    let lifecycleState: MeetingLifecycleState
    let processingJobs: [ProcessingJob]
    let hasSavedAudio: Bool
    let lastProcessingError: String?
    let privacyReceipt: PrivacyReceipt?
    let skillReceipts: [MeetingSkillReceipt]
    let presentation: MeetingDetailPresentation

    /// The section renders only when it has something trustworthy to say:
    /// processing state, a privacy receipt, or at least one skill receipt.
    static func make(
        detail: MeetingReviewReadModel,
        skillReceipts: [MeetingSkillReceipt],
        presentation: MeetingDetailPresentation
    ) -> MeetingDetailTrustValues? {
        let hasProcessingState = detail.meeting.lifecycleState == .needsAttention
            || detail.processingJobs.contains {
                $0.state == .pending || $0.state == .running || $0.state == .failed
            }
        guard hasProcessingState || detail.privacyReceipt != nil
            || !skillReceipts.isEmpty
        else { return nil }
        return MeetingDetailTrustValues(
            lifecycleState: detail.meeting.lifecycleState,
            processingJobs: detail.processingJobs,
            hasSavedAudio: detail.meeting.audioDirectory != nil,
            lastProcessingError: detail.meeting.lastProcessingError,
            privacyReceipt: detail.privacyReceipt,
            skillReceipts: skillReceipts,
            presentation: presentation)
    }
}

struct MeetingDetailTrustActions {
    let retryProcessing: @MainActor () async -> Void
    let refineSavedAudio: @MainActor () -> Void
    let openSupportDiagnostics: @MainActor () -> Void
}

/// Trustworthy processing and privacy state for one reviewed meeting.
///
/// Retry progress is local presentation state. Recovery and navigation remain
/// explicit actions owned by the route composition.
struct MeetingDetailTrustSection: View {
    let values: MeetingDetailTrustValues
    let actions: MeetingDetailTrustActions

    @State private var retryingProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            processingStatus
            privacyReceiptSection
            skillReceiptSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-trust-section")
    }

    /// Q12/D316: every durable skill execution for this meeting — the
    /// auditable answer to "what did Portavoz do on my behalf here".
    @ViewBuilder
    private var skillReceiptSection: some View {
        if !values.skillReceipts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Skill runs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(values.skillReceipts) { receipt in
                    HStack(spacing: 6) {
                        Image(systemName: receipt.state == .succeeded
                            ? "checkmark.seal"
                            : "exclamationmark.triangle")
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
        if receipt.skillID == EmailRecapDraftSkill.id {
            switch receipt.state {
            case .succeeded:
                return L10n.text("Email recap draft — handoff requested")
            case .failed:
                return L10n.text("Email recap draft — did not open")
            case .executing:
                return L10n.text(
                    "Email recap draft — handoff status unknown")
            case .proposed, .previewed, .confirmed, .dismissed:
                return L10n.format(
                    "%@ — did not finish",
                    L10n.text("Email recap draft"))
            }
        }
        if receipt.skillID == SecretGistPublishSkill.id {
            switch receipt.state {
            case .succeeded:
                return L10n.text("Secret Gist — published")
            case .failed, .executing:
                return L10n.text(
                    "Secret Gist — outcome unknown, check GitHub")
            case .proposed, .previewed, .confirmed, .dismissed:
                return L10n.format(
                    "%@ — did not finish",
                    L10n.text("Secret Gist publication"))
            }
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
    private var processingStatus: some View {
        let failed = values.processingJobs.filter { $0.state == .failed }
        let active = values.processingJobs.filter {
            $0.state == .pending || $0.state == .running
        }
        if !failed.isEmpty {
            failedProcessingCard(failed)
        } else if !active.isEmpty {
            activeProcessingCard(active)
        } else if values.lifecycleState == .needsAttention {
            recordingRecoveryCard
        }
    }

    private func failedProcessingCard(_ jobs: [ProcessingJob]) -> some View {
        processingCard(tint: .orange) {
            Label(
                "Processing needs attention",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail-processing-status")
            Text(failedProcessingExplanation(jobs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            retryProcessingButton
        }
    }

    private var retryProcessingButton: some View {
        Button {
            retryingProcessing = true
            Task {
                await actions.retryProcessing()
                retryingProcessing = false
            }
        } label: {
            if retryingProcessing {
                ProgressView().controlSize(.small)
            } else {
                Label("Retry processing", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(retryingProcessing)
        .accessibilityIdentifier("detail-retry-processing")
    }

    private func activeProcessingCard(_ jobs: [ProcessingJob]) -> some View {
        processingCard(tint: PVDesign.accent) {
            Label("Processing on this Mac", systemImage: "gearshape.2")
                .font(.headline)
                .foregroundStyle(PVDesign.accent)
                .accessibilityIdentifier("detail-processing-status")
            Text(activeProcessingExplanation(jobs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep Portavoz open; recovery continues automatically.")
                .font(.caption.weight(.semibold))
        }
    }

    private var recordingRecoveryCard: some View {
        processingCard(tint: .orange) {
            Label(
                "Recording needs recovery",
                systemImage: "waveform.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail-processing-status")
            Text(recoveryExplanation(values.lastProcessingError))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            processingRecoveryAction
        }
    }

    @ViewBuilder
    private var processingRecoveryAction: some View {
        if values.hasSavedAudio {
            Button("Refine saved audio", action: actions.refineSavedAudio)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("detail-recover-with-refine")
                .help(L10n.text(
                    "Re-transcribe the saved audio with Whisper, then review the result before applying it."))
        } else {
            Button("Open support diagnostics", action: actions.openSupportDiagnostics)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("detail-open-support-diagnostics")
        }
    }

    private func processingCard<Content: View>(
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(tint.opacity(0.2), lineWidth: 1))
    }

    private func failedProcessingExplanation(_ jobs: [ProcessingJob]) -> String {
        let kinds = Set(jobs.map(\.kind))
        if kinds.contains(.transcription) {
            return L10n.text(
                // One-line UI explanation.
                // swiftlint:disable:next line_length
                "Transcript recovery stopped after repeated attempts. Your audio and current transcript are still saved.")
        }
        if kinds.contains(.diarization) {
            return L10n.text(
                "Speaker recovery stopped after repeated attempts. Your audio and transcript are still saved.")
        }
        return L10n.text(
            "Background processing stopped after repeated attempts. Your meeting is still saved.")
    }

    private func activeProcessingExplanation(_ jobs: [ProcessingJob]) -> String {
        if jobs.contains(where: { $0.kind == .transcription }) {
            return L10n.text("Recovering the complete transcript from finalized audio.")
        }
        if jobs.contains(where: { $0.kind == .diarization }) {
            return L10n.text("Recovering speaker attribution from finalized audio.")
        }
        return L10n.text("Finishing local background processing for this meeting.")
    }

    private func recoveryExplanation(_ code: String?) -> String {
        switch code {
        case "transcription.empty":
            L10n.text(
                // One-line UI explanation.
                // swiftlint:disable:next line_length
                "Your audio is safe. The automatic pass found no reliable speech. Refine re-transcribes the saved audio with Whisper and lets you review the result before replacing anything.")
        case "capture.publication.failed":
            L10n.text("Portavoz preserved recovery evidence but could not finalize the recording.")
        default:
            L10n.text("Portavoz preserved the meeting, but automatic recovery could not finish.")
        }
    }

    @ViewBuilder
    private var privacyReceiptSection: some View {
        if let receipt = values.privacyReceipt {
            let tint = privacyReceiptTint(receipt.status)
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy receipt", systemImage: privacyReceiptIcon(receipt.status))
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
        case .allContentStayedOnDevice: "lock.shield.fill"
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
        case .summaryGeneration: L10n.text("Summary material")
        case .publishGitHubGist: L10n.text("Meeting export")
        case .createGitHubIssue: L10n.text("GitHub action item")
        case .createLinearIssue: L10n.text("Linear action item")
        }
    }
}
