import PortavozCore
import SwiftUI

/// What a meeting without a summary offers, and — when its automatic summary
/// was cancelled — why it never arrived.
///
/// A cancelled job is not a failure, so the meeting stays `ready` with its
/// audio and transcript intact and neither the processing card nor the library
/// row mentions it. D233 keeps summary regeneration an explicit user action,
/// which makes the missing piece the signal rather than an unrequested model
/// run: the explanation sits directly above the button that repairs it.
struct MeetingDetailSummaryPlaceholder: View {
    let processingJobs: [ProcessingJob]
    let generate: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            abandonedNotice
            Button(action: generate) {
                Label("Generate summary", systemImage: "sparkles")
            }
            .accessibilityIdentifier("detail-generate-summary")
        }
    }

    @ViewBuilder
    private var abandonedNotice: some View {
        if let cancelled = latestCancelledSummary {
            Label(explanation(cancelled.errorCode), systemImage: "sparkles.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("detail-summary-abandoned")
        }
    }

    private var latestCancelledSummary: ProcessingJob? {
        processingJobs
            .filter { $0.kind == .summary && $0.state == .cancelled }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func explanation(_ code: String?) -> String {
        switch code {
        case "processing.input.superseded":
            L10n.text(
                // One-line UI explanation.
                "The automatic summary stopped because this transcript changed. Nothing was lost.")
        case "processing.summary.unavailable":
            L10n.text("The automatic summary could not run with the configured engine.")
        default:
            L10n.text("The automatic summary did not finish for this meeting.")
        }
    }
}
