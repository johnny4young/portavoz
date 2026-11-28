import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// Global triage for generated work: each suggestion says who said it and
/// where, and confirms through the same editor Meeting Detail uses.
struct CommitmentReviewQueueView: View {
    let model: CommitmentRadarModel
    let onOpenMeeting: (MeetingID, TimeInterval?) -> Void

    @State private var confirming: CommitmentReviewQueueItem?

    private var state: CommitmentRadarModel.State { model.state }

    @ViewBuilder
    var body: some View {
        switch state.reviewPhase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading suggestions to review…")
                    .foregroundStyle(.ink3)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t load suggestions", systemImage: PVSymbol.warning)
            } description: {
                Text("Nothing was confirmed or changed.")
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
                Text("New suggestions and due items will appear here.")
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
        let rows = state.reviewRows
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggestions, not commitments")
                    .pvDisplay(.section)
                    .foregroundStyle(PVDesign.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                if page.hasMore {
                    Text(L10n.format(
                        "Showing %d of %d suggestions",
                        page.items.count,
                        page.totalCount))
                        .font(.subheadline)
                        .foregroundStyle(.ink3)
                }
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    CommitmentReviewRow(
                        row: row,
                        isFirst: row.id == rows.first?.id,
                        isBusy: state.reviewingActionItemID != nil,
                        actions: actions(for: row.item))
                }
            }
        }
        .accessibilityIdentifier("commitment-review-page")
        .sheet(item: $confirming) { item in
            MeetingCommitmentConfirmationSheet(
                text: item.actionItem.text,
                suggestedOwner: item.suggestedOwner?.suggestion,
                ownerChoices: state.reviewVoices.ownerChoices(for: item.meetingID, suggested: item.suggestedOwner),
                cancel: { confirming = nil },
                confirm: { title, assignee, dueAt in
                    await model.confirmReview(item, title: title, assignee: assignee, dueAt: dueAt)
                })
        }
    }

    func actions(for item: CommitmentReviewQueueItem) -> CommitmentReviewRow.Actions {
        CommitmentReviewRow.Actions(
            confirm: { confirming = item },
            open: { onOpenMeeting(item.meetingID, $0) },
            deferDays: { days in
                guard let revisitAt = Calendar.autoupdatingCurrent.date(
                    byAdding: .day, value: days, to: Date())
                else { return }
                Task {
                    await model.send(.deferReview(
                        meetingID: item.meetingID,
                        actionItemID: item.id,
                        revisitAt: revisitAt))
                }
            },
            dismiss: {
                Task {
                    await model.send(.dismissReview(
                        meetingID: item.meetingID,
                        actionItemID: item.id))
                }
            },
            presented: {
                Task {
                    await model.send(.reviewCandidatePresented(
                        meetingID: item.meetingID,
                        actionItemID: item.id))
                }
            })
    }
}

/// One suggestion: the task, who said it, the owner Portavoz suggests, the
/// meeting, its moments on the voice strip, and the four decisions.
private struct CommitmentReviewRow: View {
    struct Actions {
        let confirm: () -> Void
        let open: (TimeInterval?) -> Void
        let deferDays: (Int) -> Void
        let dismiss: () -> Void
        let presented: () -> Void
    }

    static let stripWidth: CGFloat = 460
    /// A shade under the section heading, so the list reads as items, not headings.
    static let titleStyle = PVDisplayStyle(size: 19.5, weight: 440, relativeTo: .title3)

    let row: CommitmentReviewPresentation.Row
    let isFirst: Bool
    let isBusy: Bool
    let actions: Actions

    private var id: String { row.item.id.uuidString }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VoiceDot(tint: row.speaker?.tint ?? .grey, size: 13, isOpen: true)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(verbatim: row.item.actionItem.text)
                    .pvDisplay(Self.titleStyle)
                    .foregroundStyle(PVDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                attribution
                moments
                decisions
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(PVDesign.line).frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-review-item-\(id)")
        .onAppear(perform: actions.presented)
    }

    private var attribution: some View {
        FlowLayout(spacing: 10, rowSpacing: 6) {
            if let speaker = row.speaker {
                HStack(spacing: 6) {
                    VoiceDot(tint: speaker.tint, size: 7)
                    Text(speaker.saidIt)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("commitment-review-speaker-\(id)")
            }
            if let owner = row.ownerChip {
                SuggestionChip(kind: .ai, text: owner)
                    .accessibilityIdentifier("commitment-review-owner-\(id)")
            }
            Text(verbatim: row.meeting())
                .accessibilityIdentifier("commitment-review-meeting-\(id)")
        }
        .font(.subheadline)
        .foregroundStyle(.ink3)
    }

    @ViewBuilder
    private var moments: some View {
        if row.item.evidence.status == .current {
            HStack(spacing: 12) {
                if let strip = row.strip {
                    VoiceStrip(strip, size: .card, marks: row.moments)
                        .frame(minWidth: 96, maxWidth: Self.stripWidth)
                        .accessibilityIdentifier("commitment-review-strip-\(id)")
                }
                times
            }
            .padding(.top, 2)
        } else {
            MeetingEvidenceSources(
                resolution: row.item.evidence,
                sourceIdentifier: "commitment-review-\(id)-evidence",
                staleIdentifier: "commitment-review-\(id)-stale",
                unavailableIdentifier: "commitment-review-\(id)-unavailable",
                clock: CommitmentReviewPresentation.clock,
                focus: { actions.open($0.startTime) })
        }
    }

    private var times: some View {
        HStack(spacing: 4) {
            ForEach(Array(row.shownSegments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 { Text(verbatim: "·").foregroundStyle(.ink3) }
                Button {
                    actions.open(segment.startTime)
                } label: {
                    Text(CommitmentReviewPresentation.clock(segment.startTime))
                        .font(PVFont.timeCode(.subheadline))
                        .foregroundStyle(PVDesign.ink2)
                }
                .buttonStyle(.plain)
                .help(segment.text)
                .accessibilityValue(segment.text)
                .accessibilityIdentifier("commitment-review-\(id)-evidence-\(index)")
            }
            if row.hiddenMomentCount > 0 {
                Text(verbatim: "+\(row.hiddenMomentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.ink3)
                    .accessibilityLabel(L10n.format(
                        "Showing %d of %d excerpts", row.shownSegments.count, row.item.evidenceCount))
                    .accessibilityIdentifier("commitment-review-evidence-truncated-\(id)")
            }
        }
        .fixedSize()
    }

    private var decisions: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            Button(action: actions.confirm) {
                Label("Confirm", systemImage: "checkmark")
                    .labelStyle(CommitmentReviewLabelStyle())
            }
            .buttonStyle(.pvPrimary)
            .disabled(!row.canConfirm)
            .help(row.canConfirm
                ? L10n.text("Review the wording, owner, deadline, and source before confirming.")
                : L10n.text("Regenerate the summary before confirming this stale source."))
            .accessibilityIdentifier("commitment-review-confirm-\(id)")

            Button("Review in meeting") {
                actions.open(row.firstMoment)
            }
            .buttonStyle(.pvSecondary)
            .help("Open the full meeting before confirming.")
            .accessibilityIdentifier("commitment-review-open-\(id)")

            Menu("Later") {
                Button("Tomorrow") { actions.deferDays(1) }
                    .accessibilityIdentifier("commitment-review-defer-tomorrow-\(id)")
                Button("Next week") { actions.deferDays(7) }
                    .accessibilityIdentifier("commitment-review-defer-week-\(id)")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(QuietAction())
            .accessibilityIdentifier("commitment-review-defer-\(id)")

            Button("Dismiss", action: actions.dismiss)
                .modifier(QuietAction())
                .accessibilityIdentifier("commitment-review-dismiss-\(id)")
        }
        .padding(.top, 2)
        .controlSize(.small)
        .disabled(isBusy)
    }
}

/// Later and Dismiss: text actions that stay quieter than Confirm.
private struct QuietAction: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(PVDesign.ink2)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .contentShape(.rect)
    }
}

private struct CommitmentReviewLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
