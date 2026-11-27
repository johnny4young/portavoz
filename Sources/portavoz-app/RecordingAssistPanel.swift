import ApplicationKit
import PortavozCore
import SwiftUI

/// Which companion cards the person has not seen. Identity decides, so a card
/// replaced in place counts as unread even when the number of cards stays the same.
struct RecordingAssistUnread: Equatable {
    private(set) var seen: Set<UUID> = []

    func count(in ids: Set<UUID>) -> Int {
        ids.subtracting(seen).count
    }

    mutating func observe(_ ids: Set<UUID>, showingCompanion: Bool) {
        seen = showingCompanion ? ids : seen.intersection(ids)
    }

    mutating func markSeen(_ ids: Set<UUID>) {
        seen = ids
    }
}

/// The live assist area: a tab bar, one focus slot, exactly one open panel,
/// and the note field.
///
/// Eight panels used to share a single 260 pt scroll — catch-up, next
/// question, interview assist, objectives, proactive assist, Companion cards,
/// notes and the live summary — with the Companion list unbounded inside it.
/// Now one panel is open at a time, the area grows with the window, and
/// whatever cannot wait for a tab switch is lifted into the focus slot under
/// the tabs (D504).
struct RecordingAssistPanel: View {
    @Bindable var controller: RecordingController
    /// Resolved by the composition (it knows the detector and answer engines).
    let apuntadorState: RecordingApuntadorState
    let openApuntadorSettings: @MainActor () -> Void
    /// Owned here so switching tabs does not reset what the user opened.
    @State private var presentations: [UUID: CompanionCardPresentation] = [:]
    @State private var companionUnread = RecordingAssistUnread()

    private var tab: RecordingAssistTab { controller.selectedAssistTab }

    private var companionIDs: Set<UUID> {
        Set(controller.companionCards.map(\.id))
    }

    private var focusCard: CompanionCard? {
        CompanionCardWindow.focusCard(controller.companionCards)
    }

    private var slot: RecordingFocusSlot {
        RecordingFocusSlot.resolve(
            hasCatchUp: controller.catchUp.state != nil,
            directedCardID: focusCard?.id,
            hasNextQuestion: controller.nextQuestion.state != nil)
    }

    var body: some View {
        VStack(spacing: 10) {
            tabBar
            focusSlot
            activePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            RecordingNoteField(controller: controller)
        }
        .onChange(of: companionIDs, initial: true) { _, ids in
            companionUnread.observe(ids, showingCompanion: tab == .companion)
            presentations = presentations.filter { ids.contains($0.key) }
        }
        .onChange(of: tab) { _, current in
            guard current == .companion else { return }
            companionUnread.markSeen(companionIDs)
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
                RecordingAskedYouHeader(card: card, voices: controller.liveVoices)
                Spacer(minLength: 4)
                Button {
                    controller.dismissCompanionCard(card.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.ink3)
                .help(L10n.text("Dismiss this card"))
                .accessibilityLabel(L10n.text("Dismiss this card"))
                .accessibilityIdentifier("recording-focus-dismiss")
            }
            // The question is quoted as heard.
            Text(verbatim: "“\(card.question)”")
                .pvDisplay(.heard.sized(17))
                .foregroundStyle(PVDesign.ink)
                .lineLimit(3)
            if !card.answer.isEmpty {
                Text(Self.answer(card.answer))
                    .foregroundStyle(PVDesign.ink2)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .lineLimit(5)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PVDesign.card, in: RoundedRectangle(cornerRadius: PVDesign.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PVDesign.radiusCard, style: .continuous)
                .strokeBorder(PVDesign.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-focus-card")
    }

    /// "Portavoz: …" with the speaker in green, as one wrapping run.
    static func answer(_ text: String) -> AttributedString {
        var speaker = AttributedString(L10n.text("Portavoz:"))
        speaker.foregroundColor = PVDesign.green
        speaker.font = .system(size: 12.5, weight: .semibold)
        return speaker + AttributedString(" " + text)
    }
}

/// "S2 asked you · 11:20": who asked, from the live tick for this card, so
/// only this line follows a relabel.
private struct RecordingAskedYouHeader: View {
    let card: CompanionCard
    let voices: RecordingLiveVoicesModel

    var body: some View {
        let key = voices.ticks.lazy.compactMap { tick -> String? in
            guard tick.id == card.id, case .askedYou(let by) = tick.kind else { return nil }
            return by
        }.first
        HStack(spacing: 6) {
            VoiceDot(tint: key.map { voices.cast.tint(for: $0) } ?? .grey, size: 9)
            Text(LiveVoiceName.asker(key).map { L10n.format("%@ asked you", $0) } ?? L10n.text("They asked you"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PVDesign.ink)
            Text(verbatim: "· \(ClockFormat.mmss(card.askedAt))")
                .font(PVFont.timeCode(.caption))
                .foregroundStyle(.ink3)
        }
        .lineLimit(1)
    }
}

// MARK: - Tab bar

private extension RecordingAssistPanel {
    var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(RecordingAssistTab.allCases) { candidate in
                tabButton(candidate)
            }
            Spacer(minLength: 0)
            RecordingApuntadorStateChip(
                state: apuntadorState,
                turnOn: { controller.companionEnabled = true },
                turnOff: { controller.companionEnabled = false },
                openSettings: openApuntadorSettings)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-assist-tabs")
    }

    func tabButton(_ candidate: RecordingAssistTab) -> some View {
        let isActive = candidate == tab
        let badge = candidate == .companion
            ? companionUnread.count(in: companionIDs)
            : 0
        return Button {
            controller.selectedAssistTab = candidate
        } label: {
            HStack(spacing: 4) {
                RecordingAssistTabTitle(tab: candidate, controller: controller)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(PVDesign.onInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(PVDesign.ink, in: Capsule())
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle().fill(PVDesign.ink).frame(height: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(PVDesign.ink) : AnyShapeStyle(.ink3))
        .accessibilityIdentifier("recording-assist-tab-\(candidate.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A tab's title; only Notes reads the note count, so a new note redraws this
/// label and not the panel.
private struct RecordingAssistTabTitle: View {
    let tab: RecordingAssistTab
    let controller: RecordingController

    var body: some View {
        let count = tab == .notes ? controller.contextItems.count : 0
        Text(count > 0 ? L10n.format("Notes · %d", count) : tab.title)
            .font(.system(size: 12, weight: .semibold))
    }
}

// MARK: - Active panel

private extension RecordingAssistPanel {
    @ViewBuilder
    var activePanel: some View {
        switch tab {
        case .companion:
            unifiedApuntadorTab
        case .objectives:
            objectivesScroller
        case .notes:
            RecordingNotesPanel(controller: controller)
        }
    }

    var objectivesScroller: some View {
        ScrollViewReader { objectiveScroll in
            ScrollView {
                RecordingObjectivesPanel(controller: controller)
            }
            .scrollsToAddedObjective(controller, objectiveScroll)
        }
    }

    @ViewBuilder
    var unifiedApuntadorTab: some View {
        let hasExtras = controller.interviewAssist.isEnabled || controller.proactiveAssist.isEnabled
        if hasExtras {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.interviewAssist.isEnabled {
                        RecordingInterviewAssistView(controller: controller)
                    }
                    if controller.proactiveAssist.isEnabled {
                        RecordingProactiveAssistView(controller: controller)
                    }
                    RecordingCompanionCardsView(
                        controller: controller,
                        presentations: $presentations,
                        focused: focusedCardID,
                        emptyMessage: apuntadorState.explanation)
                }
                .padding(.vertical, 2)
            }
        } else {
            RecordingCompanionCardsView(
                controller: controller,
                presentations: $presentations,
                focused: focusedCardID,
                emptyMessage: apuntadorState.explanation)
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
                Label(L10n.text("Catch me up"), systemImage: PVSymbol.history)
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.ink3)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-catch-up-panel")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("Catching you up…"))
                    .foregroundStyle(.ink3)
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
                .foregroundStyle(.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func scrollsToAddedObjective(
        _ controller: RecordingController, _ proxy: ScrollViewProxy
    ) -> some View {
        onChange(of: controller.objectives.objectives.map(\.id)) { previous, current in
            let previousIDs = Set(previous)
            guard let added = current.last(where: { !previousIDs.contains($0) }) else { return }
            proxy.scrollTo(added, anchor: .center)
        }
    }
}
