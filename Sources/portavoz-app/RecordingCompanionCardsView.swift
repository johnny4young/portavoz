import PortavozCore
import SwiftUI

/// The Companion tab: the newest few cards open to a bounded height, older
/// ones folded down to their question. Before D504 every card rendered at its
/// full ideal height with `.fixedSize`, so a single long answer could fill the
/// whole panel and a meeting's worth of cards became several screens of
/// scrolling.
struct RecordingCompanionCardsView: View {
    @Bindable var controller: RecordingController
    /// Owned by the panel so a tab switch does not reset what the user opened.
    @Binding var presentations: [UUID: CompanionCardPresentation]
    /// The card lifted into the focus slot, so the list does not repeat it.
    let focused: UUID?

    private var rows: [CompanionCardWindow.Row] {
        CompanionCardWindow.rows(
            cards: controller.companionCards,
            focused: focused,
            overrides: presentations)
    }

    var body: some View {
        if rows.isEmpty {
            RecordingAssistEmptyState(
                symbol: "questionmark.bubble",
                message: L10n.text("Questions the meeting asks you show up here."))
        } else {
            ScrollView {
                // A plain stack, not a lazy one: the window bounds this list to
                // a few open cards plus one-line folded rows, and a lazy stack
                // never builds what sits below the fold — which puts the folded
                // rows out of reach of VoiceOver until the user scrolls to them.
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        card(row, ordinal: index)
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-companion-list")
        }
    }

    @ViewBuilder
    private func card(_ row: CompanionCardWindow.Row, ordinal: Int) -> some View {
        if row.presentation == .collapsed {
            collapsedRow(row, ordinal: ordinal)
        } else {
            openCard(row, ordinal: ordinal)
        }
    }

    /// One line: the question and when it was asked. Everything past the
    /// recency window folds down to this instead of leaving the panel.
    private func collapsedRow(
        _ row: CompanionCardWindow.Row,
        ordinal: Int
    ) -> some View {
        Button {
            presentations[row.card.id] = .clamped
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(ClockFormat.mmss(row.card.askedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(row.card.question)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("recording-companion-folded-\(ordinal)")
    }

    private func openCard(
        _ row: CompanionCardWindow.Row,
        ordinal: Int
    ) -> some View {
        let card = row.card
        let tint: Color = card.directed ? .orange : PVDesign.accent
        return VStack(alignment: .leading, spacing: 6) {
            header(row, ordinal: ordinal)
            if !card.answer.isEmpty {
                answer(row)
            }
            footer(row, tint: tint, ordinal: ordinal)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-companion-card-\(ordinal)")
    }

    private func header(_ row: CompanionCardWindow.Row, ordinal: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(row.card.question, systemImage: "questionmark.bubble.fill")
                .font(.callout.weight(.semibold))
                .lineLimit(row.presentation == .full ? nil : 2)
            Spacer(minLength: 4)
            Button {
                presentations[row.card.id] = .collapsed
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(L10n.text("Fold this card"))
            .accessibilityIdentifier("recording-companion-fold-\(ordinal)")
            Button {
                controller.dismissCompanionCard(row.card.id)
                presentations[row.card.id] = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Dismiss this card"))
            .accessibilityIdentifier("recording-companion-dismiss-\(ordinal)")
        }
    }

    private func answer(_ row: CompanionCardWindow.Row) -> some View {
        Text(row.card.answer)
            .font(.callout)
            .textSelection(.enabled)
            // A bounded card is the whole point: only a card the user opened
            // in full is allowed to take its ideal height.
            .lineLimit(
                row.presentation == .full
                    ? nil : CompanionCardWindow.clampedAnswerLines)
            .fixedSize(
                horizontal: false,
                vertical: row.presentation == .full)
    }

    private func footer(
        _ row: CompanionCardWindow.Row,
        tint: Color,
        ordinal: Int
    ) -> some View {
        HStack(spacing: 8) {
            Text(RecordingCompanionCardsView.tag(row.card))
                .font(.caption2)
                .foregroundStyle(row.card.directed ? tint : Color.secondary)
            if row.canOpenFully {
                Button(L10n.text("Show all")) {
                    presentations[row.card.id] = .full
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityIdentifier("recording-companion-show-all-\(ordinal)")
            } else if row.presentation == .full {
                Button(L10n.text("Show less")) {
                    presentations[row.card.id] = .clamped
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityIdentifier("recording-companion-show-less-\(ordinal)")
            }
            Spacer()
            if !row.card.answer.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.card.answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(L10n.text("Copy response"))
            }
        }
    }

    static func tag(_ card: CompanionCard) -> String {
        let base = card.kind == .context
            ? L10n.text("from this meeting")
            : L10n.format("knowledge · %@", card.source)
        if card.answer.isEmpty {
            return card.directed ? L10n.text("asked you") : L10n.text("question detected")
        }
        if card.directed {
            return "\(L10n.text("asked you")) · \(base)"
        }
        return base
    }
}

/// A tab that is reachable but has nothing yet says so, instead of opening
/// onto blank space.
struct RecordingAssistEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
