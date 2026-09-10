import IntelligenceKit
import PortavozCore
import SwiftUI

/// The live assist area: one focus slot, a tab bar, and exactly one open panel.
///
/// Eight panels used to share a single 260 pt scroll — catch-up, next
/// question, interview assist, objectives, proactive assist, Companion cards,
/// notes and the live summary — with the Companion list unbounded inside it.
/// Now one panel is open at a time, the area grows with the window, and
/// whatever cannot wait for a tab switch is lifted into the focus slot above
/// the tabs (D504).
struct RecordingAssistPanel: View {
    @Bindable var controller: RecordingController
    @State private var selection: RecordingAssistTab = .companion
    /// Owned here so switching tabs does not reset what the user opened.
    @State private var presentations: [UUID: CompanionCardPresentation] = [:]
    @State private var seenCompanionCount = 0
    /// Held here for the same reason as `presentations`: the notes panel is a
    /// branch of `activePanel` and loses its own state when the tab changes.
    @State private var noteDraft = ""

    private var tabs: [RecordingAssistTab] {
        RecordingAssistTab.available(
            interviewEnabled: controller.interviewAssist.isEnabled,
            proactiveEnabled: controller.proactiveAssist.isEnabled,
            hasSummary: controller.liveSummary != nil)
    }

    private var tab: RecordingAssistTab {
        RecordingAssistTab.resolve(selection, in: tabs)
    }

    private var focusCard: CompanionCard? {
        CompanionCardWindow.focusCard(controller.companionCards)
    }

    private var slot: RecordingFocusSlot {
        RecordingFocusSlot.resolve(
            hasCatchUp: controller.catchUp.state != nil,
            directedCardID: focusCard?.id,
            statedPriorityID: controller.priorityOffer?.id,
            hasNextQuestion: controller.nextQuestion.state != nil)
    }

    var body: some View {
        VStack(spacing: 8) {
            focusSlot
            tabBar
            activePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: controller.companionCards.count) { _, count in
            seenCompanionCount = tab == .companion
                ? count
                : min(seenCompanionCount, count)
        }
        .onChange(of: tab) { _, current in
            guard current == .companion else { return }
            seenCompanionCount = controller.companionCards.count
        }
        // Without this the container identifier propagates onto every leaf
        // and shadows the inner ones, so the focus card becomes unaddressable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-assist-panel")
    }
}

// MARK: - Focus slot

private extension RecordingAssistPanel {
    /// The card in the focus slot must not repeat inside the Companion list.
    var focusedCardID: UUID? {
        if case .directedCard(let id) = slot { return id }
        return nil
    }

    @ViewBuilder
    var focusSlot: some View {
        switch slot {
        case .none:
            EmptyView()
        case .catchUp:
            if let state = controller.catchUp.state {
                RecordingCatchUpCard(state: state) { controller.catchUp.dismiss() }
            }
        case .directedCard:
            if let card = focusCard {
                directedCard(card)
            }
        case .statedPriority:
            if let offer = controller.priorityOffer {
                priorityCard(offer)
            }
        case .nextQuestion:
            if let state = controller.nextQuestion.state {
                RecordingNextQuestionCard(state: state) {
                    controller.nextQuestion.dismiss()
                }
            }
        }
    }

    /// A question addressed to the user by name. In one real meeting two of
    /// twenty-three cards were directed and both sat at the same weight as the
    /// other twenty-one; this is the slot they earn.
    func directedCard(_ card: CompanionCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(L10n.text("They asked you"), systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(ClockFormat.mmss(card.askedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    controller.dismissCompanionCard(card.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Dismiss this card"))
                .accessibilityIdentifier("recording-focus-dismiss")
            }
            Text(card.question)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            if !card.answer.isEmpty {
                Text(card.answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-focus-card")
    }
    /// A priority somebody declared out loud. Inert: it names what was said
    /// and who to believe (the caption, at its timestamp), and does nothing
    /// until the user turns it into an objective (D505).
    func priorityCard(_ offer: StatedPriority) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(L10n.text("Stated priority"), systemImage: "flag.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Text(ClockFormat.mmss(offer.statedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(offer.subject)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            // The exact caption, so the user judges the claim rather than
            // trusting it.
            Text(offer.statement)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Button(L10n.text("Track as objective")) {
                    controller.acceptPriorityOffer()
                }
                .controlSize(.small)
                .accessibilityIdentifier("recording-priority-accept")
                .disabled(controller.priorityAcceptanceRefused)
                Button(L10n.text("Not a priority")) {
                    controller.dismissPriorityOffer()
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recording-priority-dismiss")
                Spacer()
            }
            if controller.priorityAcceptanceRefused {
                // The objectives list refused it. Saying so here beats clearing
                // the card and losing the acceptance for the rest of the
                // meeting, which is what used to happen.
                Text(L10n.text("Your objectives list is full — remove one to track this."))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recording-priority-refused")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.tint.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-priority-card")
    }
}

// MARK: - Tab bar

private extension RecordingAssistPanel {
    var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { candidate in
                tabButton(candidate)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-assist-tabs")
    }

    func tabButton(_ candidate: RecordingAssistTab) -> some View {
        let isActive = candidate == tab
        let badge = candidate == .companion
            ? CompanionCardWindow.unseen(
                liveCount: controller.companionCards.count,
                seenCount: seenCompanionCount)
            : 0
        return Button {
            selection = candidate
        } label: {
            HStack(spacing: 4) {
                Image(systemName: candidate.symbol).font(.caption)
                Text(candidate.title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                isActive ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .accessibilityIdentifier("recording-assist-tab-\(candidate.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Active panel

private extension RecordingAssistPanel {
    @ViewBuilder
    var activePanel: some View {
        switch tab {
        case .companion:
            RecordingCompanionCardsView(
                controller: controller,
                presentations: $presentations,
                focused: focusedCardID)
        case .objectives:
            objectivesTab
        case .notes:
            RecordingNotesPanel(controller: controller, draft: $noteDraft)
        case .interview:
            ScrollView { RecordingInterviewAssistView(controller: controller) }
        case .proactive:
            ScrollView { RecordingProactiveAssistView(controller: controller) }
        case .summary:
            summaryTab
        }
    }

    var objectivesTab: some View {
        ScrollViewReader { objectiveScroll in
            ScrollView {
                RecordingObjectivesPanel(controller: controller)
            }
            .onChange(of: controller.objectives.objectives.map(\.id)) { previous, current in
                guard current.count == previous.count + 1,
                      let added = current.first(where: { !previous.contains($0) })
                else { return }
                objectiveScroll.scrollTo(added, anchor: .center)
            }
        }
    }

    @ViewBuilder
    var summaryTab: some View {
        if let markdown = controller.liveSummary {
            ScrollView {
                MarkdownText(text: markdown)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("recording-live-summary")
        } else {
            RecordingAssistEmptyState(
                symbol: "sparkles",
                message: L10n.text("A running summary appears once there is enough to say."))
        }
    }
}

/// The pull-based recap (D26): generating, the recap itself, or the honest
/// capability/insufficient-content explanation. Dismiss is the only other
/// action — this card never persists anywhere.
struct RecordingCatchUpCard: View {
    let state: RecordingCatchUpModel.State
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("Catch me up"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Dismiss catch-up"))
                .accessibilityIdentifier("recording-catch-up-dismiss")
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("recording-catch-up-panel")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("Catching you up…"))
                    .foregroundStyle(.secondary)
            }
        case .ready(let recap):
            // The recap is why the user pressed the button, but it must not
            // push the tabs off screen: it scrolls inside the slot instead.
            ScrollView {
                MarkdownText(text: recap).font(.callout)
            }
            .frame(maxHeight: 180)
        case .unavailable(let reason):
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
