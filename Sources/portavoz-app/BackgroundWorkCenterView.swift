import PortavozCore
import SwiftUI

struct BackgroundWorkCenterSection: View {
    let model: BackgroundWorkCenterModel
    let performAction: (BackgroundWorkOwner) -> Void

    var body: some View {
        Section {
            Text(L10n.text(
                // swiftlint:disable:next line_length
                "Recovery and local indexing continue safely in the background. Recording always comes first; Portavoz never invents progress."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("background-work-overview")

            ForEach(model.items) { snapshot in
                BackgroundWorkRow(
                    snapshot: snapshot,
                    performAction: performAction)
            }
        } header: {
            Text("Background activity")
        }
    }
}

struct BackgroundWorkIndicator: View {
    let model: BackgroundWorkCenterModel
    let openCenter: () -> Void

    var body: some View {
        if model.hasVisibleActivity {
            Button(action: openCenter) {
                Label {
                    Text(model.needsAttention
                        ? L10n.text("Background work needs attention")
                        : L10n.text("Background work active"))
                } icon: {
                    Image(systemName: model.needsAttention
                        ? "exclamationmark.arrow.triangle.2.circlepath"
                        : "arrow.triangle.2.circlepath")
                }
            }
            .help(L10n.text("Open background activity"))
            .accessibilityIdentifier("background-work-indicator")
        }
    }
}

private struct BackgroundWorkRow: View {
    let snapshot: BackgroundWorkSnapshot
    let performAction: (BackgroundWorkOwner) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(ownerTitle)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .accessibilityIdentifier(
                            "background-work-status-\(snapshot.owner.rawValue)")
                }

                if case .running = snapshot.phase {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(statusText)
                        .accessibilityIdentifier(
                            "background-work-progress-\(snapshot.owner.rawValue)")
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: detailText))
                    .accessibilityIdentifier(
                        "background-work-detail-\(snapshot.owner.rawValue)")

                if let attemptText {
                    Text(attemptText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "background-work-attempt-\(snapshot.owner.rawValue)")
                }

                if let retryText {
                    Text(retryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "background-work-retry-\(snapshot.owner.rawValue)")
                }

                if let failureText {
                    Text(L10n.format("Reason: %@", failureText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "background-work-failure-\(snapshot.owner.rawValue)")
                }

                if let actionTitle {
                    Button(actionTitle) {
                        performAction(snapshot.owner)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "background-work-action-\(snapshot.owner.rawValue)")
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-work-row-\(snapshot.owner.rawValue)")
    }

    private var ownerTitle: String {
        switch snapshot.owner {
        case .recovery: L10n.text("Interrupted recordings")
        case .processing: L10n.text("Meeting processing")
        case .spotlight: L10n.text("Spotlight search")
        case .semanticIndex: L10n.text("Semantic search")
        case .memoryGraph: L10n.text("Memory graph")
        }
    }

    private var statusText: String {
        switch snapshot.phase {
        case .idle:
            L10n.text("Idle")
        case .waitingForRecording:
            L10n.text("Waiting for recording to end")
        case .retryScheduled:
            L10n.text("Retry scheduled")
        case .failed:
            L10n.text("Needs attention")
        case .running:
            runningText
        }
    }

    private var runningText: String {
        switch snapshot.stage {
        case .recoveringRecordings:
            return L10n.text("Recovering safely")
        case .processing(let kind):
            if kind == .transcription { return L10n.text("Transcribing") }
            if kind == .diarization { return L10n.text("Identifying speakers") }
            if kind == .summary { return L10n.text("Creating summary") }
            if kind == .index { return L10n.text("Updating search") }
            return L10n.text("Processing meetings")
        case .spotlightScheduled:
            return L10n.text("Scheduled")
        case .spotlightProjecting:
            return L10n.text("Preparing local search")
        case .spotlightPublishing:
            return L10n.text("Publishing local search")
        case .semanticIndexing:
            return L10n.text("Indexing locally")
        case .projectingMemoryGraph:
            return L10n.text("Rebuilding memory links")
        case nil:
            return L10n.text("Working")
        }
    }

    private var detailText: String {
        let metrics = snapshot.metrics
        switch snapshot.owner {
        case .recovery:
            return L10n.format(
                "Reconciled: %d · leases recovered: %d · deferred: %d · attention: %d",
                metrics.reconciledRecordings,
                metrics.recoveredLeases,
                metrics.deferredRecordings,
                metrics.preservedRecoveryFailures)
        case .processing:
            return L10n.format(
                "Jobs completed: %d · latest attempt: %d",
                metrics.processedJobs,
                snapshot.attempt ?? 0)
        case .spotlight:
            return L10n.text("Keeps meetings, people, and commitments findable in macOS.")
        case .semanticIndex:
            return L10n.format(
                "Indexed: %d · excluded: %d · skipped: %d",
                metrics.embeddedSegments,
                metrics.excludedSegments,
                metrics.skippedSegments)
        case .memoryGraph:
            return L10n.format(
                "Scopes rebuilt: %d · relationships published: %d",
                metrics.rebuiltGraphScopes,
                metrics.publishedGraphEdges)
        }
    }

    private var actionTitle: String? {
        switch snapshot.phase {
        case .failed, .retryScheduled:
            if snapshot.owner == .recovery {
                return L10n.text("Open Library")
            }
            return L10n.text("Retry now")
        case .idle, .running, .waitingForRecording:
            return nil
        }
    }

    private var attemptText: String? {
        snapshot.attempt.map { L10n.format("Attempt: %d", $0) }
    }

    private var retryText: String? {
        guard case .retryScheduled(let date) = snapshot.phase,
              let date
        else { return nil }
        let formatted = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        return L10n.format("Next attempt: %@", formatted)
    }

    private var failureText: String? {
        switch snapshot.lastFailure {
        case .recoveryExpiredLeases:
            L10n.text("Lease recovery")
        case .recoveryCandidates:
            L10n.text("Interrupted recording scan")
        case .recoveryPreservation:
            L10n.text("Recovery evidence")
        case .processingClaim:
            L10n.text("Job claim")
        case .processingPreservation:
            L10n.text("Processing evidence")
        case .scheduling:
            L10n.text("Retry scheduling")
        case .coordination:
            L10n.text("Owner coordination")
        case nil:
            nil
        }
    }

    private var icon: String {
        switch snapshot.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .retryScheduled: "clock.arrow.circlepath"
        case .waitingForRecording: "mic.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .idle: snapshot.lastOutcome == nil ? "circle" : "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch snapshot.phase {
        case .failed: .red
        case .retryScheduled: .orange
        case .waitingForRecording: .blue
        case .running: .accentColor
        case .idle: snapshot.lastOutcome == nil ? .secondary : .green
        }
    }
}
