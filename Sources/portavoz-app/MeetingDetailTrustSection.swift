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

    /// The section renders only while processing needs attention or is
    /// still running; privacy and action history live in the activity line.
    static func make(detail: MeetingReviewReadModel) -> MeetingDetailTrustValues? {
        let hasProcessingState = detail.meeting.lifecycleState == .needsAttention
            || detail.processingJobs.contains {
                $0.state == .pending || $0.state == .running || $0.state == .failed
            }
        guard hasProcessingState else { return nil }
        return MeetingDetailTrustValues(
            lifecycleState: detail.meeting.lifecycleState,
            processingJobs: detail.processingJobs,
            hasSavedAudio: detail.meeting.audioDirectory != nil,
            lastProcessingError: detail.meeting.lastProcessingError)
    }
}

struct MeetingDetailTrustActions {
    let retryProcessing: @MainActor () async -> Void
    let refineSavedAudio: @MainActor () -> Void
    let openSupportDiagnostics: @MainActor () -> Void
}

/// Processing state that needs the user's attention for one reviewed meeting.
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-trust-section")
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
                systemImage: PVSymbol.retry)
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
                Label("Retry processing", systemImage: PVSymbol.retry)
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
            Button("Improve from saved audio", action: actions.refineSavedAudio)
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
                "No reliable speech was found. Improve re-transcribes the saved audio and shows you a draft first.")
        case "transcription.recovery.unavailable":
            L10n.text(
                // One-line UI explanation.
                // swiftlint:disable:next line_length
                "Live captions stopped early and the saved audio carries no usable speech, so only the partial lines were kept. Your audio and notes are safe in this meeting.")
        case "capture.no-audio":
            L10n.text("Capture failed before audio could be saved. The failure record remains in your library.")
        case "capture.publication.failed":
            L10n.text("Portavoz kept the recording data but could not finish saving it.")
        default:
            L10n.text("Portavoz preserved the meeting, but automatic recovery could not finish.")
        }
    }
}
