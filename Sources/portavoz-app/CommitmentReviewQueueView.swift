import Foundation
import PortavozCore
import SwiftUI

/// Global triage for generated work. Cards may dismiss, defer, or reopen the
/// complete source, but they cannot promote a bounded preview to commitment
/// truth.
struct CommitmentReviewQueueView: View {
    let model: CommitmentRadarModel
    let onOpenMeeting: (MeetingID, TimeInterval?) -> Void

    private var state: CommitmentRadarModel.State { model.state }

    @ViewBuilder
    var body: some View {
        switch state.reviewPhase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading suggestions to review…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t load suggestions", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Nothing was confirmed or changed. Your meeting evidence is still safe.")
            } actions: {
                Button("Try again") {
                    Task { await model.send(.load) }
                }
                .accessibilityIdentifier("commitment-review-retry")
            }
        case .empty:
            ContentUnavailableView {
                Label("Nothing to review", systemImage: "checkmark.circle")
            } description: {
                Text("New evidence-backed suggestions and due deferrals will appear here.")
            }
            .accessibilityIdentifier("commitment-review-empty")
        case .loaded:
            if let page = state.reviewPage {
                reviewPage(page)
            }
        }
    }
}

private extension CommitmentReviewQueueView {
    func reviewPage(_ page: CommitmentReviewQueuePage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.format(
                    "Showing %d of %d suggestions",
                    page.items.count,
                    page.totalCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if page.hasMore {
                    Text("Only the newest suggestions are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(page.items) { item in
                reviewCard(item)
            }
        }
        .accessibilityIdentifier("commitment-review-page")
    }

    func reviewCard(_ item: CommitmentReviewQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewHeader(item)
            reviewMetadata(item)
            suggestedOwner(item)
            evidence(item)
            reviewActions(item)
        }
        .padding(16)
        .background(PVDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(PVDesign.accent.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-review-item-\(item.id.uuidString)")
    }

    func reviewHeader(_ item: CommitmentReviewQueueItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: item.actionItem.text)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Spacer()
            reasonBadge(item.reason)
        }
    }

    func reviewMetadata(_ item: CommitmentReviewQueueItem) -> some View {
        HStack(spacing: 12) {
            Label(item.meetingTitle, systemImage: "person.2")
            Text("·")
            Text(verbatim: meetingDate(item.meetingStartedAt))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    func suggestedOwner(_ item: CommitmentReviewQueueItem) -> some View {
        if let owner = item.suggestedOwner {
            Label(
                L10n.format("Suggested owner: %@", owner.displayName),
                systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "commitment-review-owner-\(item.id.uuidString)")
        }
    }

    func reviewActions(_ item: CommitmentReviewQueueItem) -> some View {
        HStack(spacing: 8) {
            dismissButton(item)
            deferMenu(item)
            Spacer()
            openMeetingButton(item)
        }
        .disabled(state.reviewingActionItemID != nil)
    }

    func dismissButton(_ item: CommitmentReviewQueueItem) -> some View {
        Button("Dismiss", role: .destructive) {
            Task {
                await model.send(.dismissReview(
                    meetingID: item.meetingID,
                    actionItemID: item.id))
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier(
            "commitment-review-dismiss-\(item.id.uuidString)")
    }

    func deferMenu(_ item: CommitmentReviewQueueItem) -> some View {
        Menu("Review later") {
            deferButton("Tomorrow", days: 1, item: item)
                .accessibilityIdentifier(
                    "commitment-review-defer-tomorrow-\(item.id.uuidString)")
            deferButton("Next week", days: 7, item: item)
                .accessibilityIdentifier(
                    "commitment-review-defer-week-\(item.id.uuidString)")
        }
        .controlSize(.small)
        .accessibilityIdentifier(
            "commitment-review-defer-\(item.id.uuidString)")
    }

    func openMeetingButton(_ item: CommitmentReviewQueueItem) -> some View {
        Button("Review in meeting") {
            onOpenMeeting(item.meetingID, firstEvidenceTime(item))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("Open the complete meeting evidence before confirming.")
        .accessibilityIdentifier(
            "commitment-review-open-\(item.id.uuidString)")
    }

    @ViewBuilder
    func evidence(_ item: CommitmentReviewQueueItem) -> some View {
        MeetingEvidenceSources(
            resolution: item.evidence,
            sourceIdentifier: "commitment-review-\(item.id.uuidString)-evidence",
            staleIdentifier: "commitment-review-\(item.id.uuidString)-stale",
            unavailableIdentifier: "commitment-review-\(item.id.uuidString)-unavailable",
            clock: clock,
            focus: { segment in
                onOpenMeeting(item.meetingID, segment.startTime)
            })
        if item.hasMoreEvidence {
            Text(L10n.format(
                "Showing %d of %d evidence excerpts",
                item.evidence.segments.count,
                item.evidenceCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "commitment-review-evidence-truncated-\(item.id.uuidString)")
        }
    }

    func deferButton(
        _ title: LocalizedStringKey,
        days: Int,
        item: CommitmentReviewQueueItem
    ) -> some View {
        Button(title) {
            guard let revisitAt = Calendar.autoupdatingCurrent.date(
                byAdding: .day,
                value: days,
                to: Date())
            else { return }
            Task {
                await model.send(.deferReview(
                    meetingID: item.meetingID,
                    actionItemID: item.id,
                    revisitAt: revisitAt))
            }
        }
    }

    func reasonBadge(_ reason: CommitmentReviewQueueReason) -> some View {
        let title: LocalizedStringKey = switch reason {
        case .newAfterMeeting: "New after meeting"
        case .deferredDue: "Ready to review"
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PVDesign.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(PVDesign.accent.opacity(0.12), in: Capsule())
    }

    func firstEvidenceTime(_ item: CommitmentReviewQueueItem) -> TimeInterval? {
        guard item.evidence.status == .current else { return nil }
        return item.evidence.segments.first?.startTime
    }

    func meetingDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    @MainActor
    func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
