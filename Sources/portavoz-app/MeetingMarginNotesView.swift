import ApplicationKit
import PortavozCore
import SwiftUI

/// Everything the transcript needs to draw decision and commitment cards
/// beside, or under, the line that produced them.
struct MeetingMarginNotesContext {
    let notes: MeetingMarginNotes
    let cast: VoiceCast
    let decisionConfirmations: [SummaryDecisionID: DecisionObservationConfirmationState]
    let ownerChoices: [CommitmentOwnerSuggestion]
    let geometry: MeetingMarginGeometry
    let confirmDecision: @MainActor (SummaryDecisionEvidence, String) -> Void
    let retractDecisionTopic: @MainActor (DecisionObservationConfirmationState.TopicLink) -> Void
    let setDone: @MainActor (ActionItem, Bool) -> Void
    let commitments: MeetingCommitmentInboxActions
    /// Set by the transcript section, which hosts the confirmation sheet.
    var review = MeetingMarginReview()
}

/// The margin's bottom in page coordinates; cards never start above it. A
/// reference, so a change re-renders only the note columns that read it.
@MainActor @Observable
final class MeetingMarginGeometry {
    var marginBottom: CGFloat = 0
}

/// Review entry points for a pending commitment, owned above the lazy rows.
struct MeetingMarginReview {
    var open: @MainActor (CommitmentInboxCandidate) -> Void = { _ in }
    var deferCandidate: @MainActor (CommitmentInboxCandidate, _ days: Int) -> Void = { _, _ in }
    var dismiss: @MainActor (CommitmentInboxCandidate) -> Void = { _ in }
    /// A review is being saved; every card's review controls wait for it.
    var isBusy = false
}

/// One row's cards, stacked. In the margin they start level with their line
/// and move down only as far as the margin's own content needs; under a line,
/// the margin sits above the transcript and nothing moves.
struct MeetingMarginNotesColumn: View {
    let notes: [MeetingMarginNote]
    let context: MeetingMarginNotesContext
    @State private var top: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes) { note in
                MeetingMarginNoteCard(note: note, context: context)
            }
        }
        .padding(.top, max(0, context.geometry.marginBottom + MeetingDetailPageMetrics.sectionSpacing - top))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(MeetingDetailPageMetrics.coordinateSpace)).minY
        } action: { top = $0 }
    }
}

private struct MeetingMarginNoteCard: View {
    let note: MeetingMarginNote
    let context: MeetingMarginNotesContext
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        switch note.kind {
        case let .decision(evidence, statement):
            decision(evidence, statement: statement)
        case .commitment(let commitment):
            self.commitment(commitment)
        }
    }

    private func decision(_ evidence: SummaryDecisionEvidence, statement: String) -> some View {
        let identifier = "margin-decision-\(evidence.id.rawValue.uuidString)"
        return VStack(alignment: .leading, spacing: 7) {
            PVCardCaption(text: L10n.text("Decision"), systemImage: "checkmark", tint: PVDesign.ink2)
            words(statement)
            // An anchored decision's evidence is current by construction.
            DecisionConfirmationControl(
                confirmation: context.decisionConfirmations[evidence.id],
                canConfirm: true,
                identifier: identifier,
                confirm: { context.confirmDecision(evidence, statement) },
                retract: context.retractDecisionTopic)
        }
        .pvCard(.outlined, padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func commitment(_ commitment: MeetingMarginNote.Commitment) -> some View {
        let item = commitment.item
        let identifier = "margin-commitment-\(item.id.uuidString)"
        let review = context.review
        return VStack(alignment: .leading, spacing: 7) {
            PVCardCaption(
                text: commitment.source.dueAt.map { L10n.format("Commitment · due %@", HomeYoursToDo.dueDay($0)) }
                    ?? L10n.text("Commitment"),
                systemImage: PVSymbol.commitment,
                tint: commitment.source.owner?.isMe == true ? PVDesign.youInk : PVDesign.ink3)
                .accessibilityIdentifier("\(identifier)-caption")
            Toggle(isOn: Binding(get: { item.isDone }, set: { context.setDone(item, $0) })) {
                words(item.text)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? PVDesign.ink3 : PVDesign.ink)
            }
            .toggleStyle(.pvCheckbox)
            .accessibilityIdentifier("\(identifier)-done")
            attribution(commitment.source)
                .accessibilityIdentifier("\(identifier)-attribution")
            if let candidate = commitment.candidate {
                HStack(spacing: 8) {
                    Button("Confirm…") { review.open(candidate) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(PVDesign.accent)
                        .accessibilityIdentifier("\(identifier)-confirm")
                        .disabled(review.isBusy)
                    .help(L10n.text("Review the wording, owner, deadline, and source before confirming."))
                    Spacer(minLength: 0)
                    reviewMenu(candidate, identifier: identifier)
                        .disabled(review.isBusy)
                }
            }
        }
        .pvCard(.outlined, padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14 * textScale, weight: .semibold))
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func reviewMenu(_ candidate: CommitmentInboxCandidate, identifier: String) -> some View {
        Menu {
            Menu("Review later") {
                Button("Tomorrow") { context.review.deferCandidate(candidate, 1) }
                    .accessibilityIdentifier("\(identifier)-defer-tomorrow")
                Button("Next week") { context.review.deferCandidate(candidate, 7) }
                    .accessibilityIdentifier("\(identifier)-defer-week")
            }
            Button("Dismiss", role: .destructive) { context.review.dismiss(candidate) }
                .accessibilityIdentifier("\(identifier)-dismiss")
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(PVDesign.ink3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("Review later"))
        .help(L10n.text("Review later"))
        .accessibilityIdentifier("\(identifier)-more")
    }

    /// "● Ana asked · ● You own it", or one clause when one person said and owns it.
    @ViewBuilder
    private func attribution(_ source: OpenItemSource) -> some View {
        let clauses = MeetingMarginAttribution.clauses(source)
        if !clauses.isEmpty {
            FlowLayout(spacing: 5, rowSpacing: 3) {
                ForEach(Array(clauses.enumerated()), id: \.offset) { index, clause in
                    HStack(spacing: 5) {
                        if index > 0 { Text(verbatim: "·").foregroundStyle(PVDesign.ink3) }
                        VoiceDot(tint: tint(clause.voice), size: 6, isOpen: !isNamed(clause.voice))
                        Text(clause.styled)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(PVDesign.ink3)
            .accessibilityElement(children: .combine)
        }
    }

    private func tint(_ voice: OpenItemSource.Voice) -> VoiceCast.Tint {
        voice.isMe ? .you : voice.speakerID.map { context.cast.tint(for: $0) } ?? .grey
    }

    private func isNamed(_ voice: OpenItemSource.Voice) -> Bool {
        voice.isMe || VoiceCast.name(voice.displayName) != nil
    }
}

/// Who said a commitment's line and who owns it, in as few clauses as are true.
enum MeetingMarginAttribution {
    struct Clause {
        let voice: OpenItemSource.Voice
        let text: String

        /// The person's name in ink and semibold; the verb stays secondary.
        var styled: AttributedString {
            var styled = AttributedString(text)
            if let range = styled.range(of: HomeYoursToDo.name(voice)) {
                styled[range].font = .caption.weight(.semibold)
                styled[range].foregroundColor = PVDesign.ink
            }
            return styled
        }
    }

    nonisolated static func clauses(_ source: OpenItemSource) -> [Clause] {
        switch (source.saidBy, source.owner) {
        case let (said?, owner?) where source.ownerSaidIt:
            let text = said.isMe || owner.isMe
                ? L10n.text("You said it and own it")
                : L10n.format("%@ said it and owns it", HomeYoursToDo.name(said))
            return [Clause(voice: said, text: text)]
        case let (said?, owner?):
            return [
                Clause(voice: said, text: HomeYoursToDo.whoSaid(said, ownerSaidIt: false)),
                Clause(voice: owner, text: ownerText(owner))
            ]
        case let (said?, nil):
            return [Clause(voice: said, text: HomeYoursToDo.whoSaid(said, ownerSaidIt: true))]
        case let (nil, owner?):
            return [Clause(voice: owner, text: ownerText(owner))]
        case (nil, nil):
            return []
        }
    }

    nonisolated private static func ownerText(_ owner: OpenItemSource.Voice) -> String {
        owner.isMe ? L10n.text("You own it") : L10n.format("%@ owns it", HomeYoursToDo.name(owner))
    }
}
