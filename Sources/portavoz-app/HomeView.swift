import ApplicationKit
import PortavozCore
import SwiftUI

/// The default destination: one screen for someone who lives in calls.
///
/// It reads the Library snapshot the sidebar observes: the next meeting as the
/// hero beside the rest of the agenda, who spoke today, the to-dos still open
/// and the meetings to pick back up.
struct HomeView: View {
    let model: LibraryModel
    @Binding var route: Route?
    let recordingActive: Bool
    let onRecord: () -> Void
    let onAsk: (String?) -> Void
    let onOpenAutomations: () -> Void
    /// Opens a meeting, at a moment when one is given.
    let onOpenMeeting: (MeetingID, TimeInterval?) -> Void
    @Environment(\.controlActiveState) private var controlActiveState

    private var state: LibraryModel.State { model.state }

    private static let maximumTomorrowEvents = 3

    /// Suggested questions: the ones a daily user types most, ready to send.
    private static let suggestedQuestions: [String] = [
        "What did I commit to this week?",
        "Which decisions were made this week?",
        "What is still open?"
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(.horizontal, PVDesign.space6)
                    .padding(.bottom, PVDesign.space6)
                    .padding(.top, PVDesign.space3)
                    .frame(maxWidth: 1240, alignment: .topLeading)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
        }
        .navigationTitle("Portavoz")
        .onAppear { perform(.refreshAutomations) }
        // Re-read when the window regains focus, e.g. after reviewing in Settings.
        .onChange(of: controlActiveState) { _, state in
            if state == .key {
                perform(.refreshAutomations)
                perform(.loadTodayWork)
            }
        }
        // Positions are never observed, so returning to Today re-reads them.
        .onChange(
            of: TodayWorkTrigger(
                loadPhase: state.loadPhase,
                revision: state.libraryRevision,
                sourceStrips: state.shownOpenItems.map { state.voiceStrips[$0.meetingID] }),
            initial: true
        ) { perform(.loadTodayWork) }
        // Re-read on library changes, so edits to the previous meeting show.
        .onChange(
            of: BriefPreviewTrigger(
                event: state.heroEvent?.event, revision: state.libraryRevision,
                sourceStrip: state.briefPreview?.lines.flatMap { state.voiceStrips[$0.sourceMeetingID] }),
            initial: true
        ) { _, trigger in
            if let event = trigger.event { perform(.loadBriefPreview(event)) }
        }
        .onChange(of: state.todayVoicesRevision, initial: true) { perform(.loadTodayVoices) }
    }

    /// Header, the hero beside the rest of the agenda, the to-dos beside the
    /// meetings to pick up, then who spoke today.
    private var content: some View {
        let rows = state.pickUpRows
        let page = state.pageCast(pickUp: rows)
        return VStack(alignment: .leading, spacing: PVDesign.space4) {
            header
            agendaSection(page)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 44) {
                    yoursToDo(page).frame(maxWidth: .infinity, alignment: .topLeading)
                    pickUp(rows, page: page).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: PVDesign.space4) {
                    yoursToDo(page)
                    pickUp(rows, page: page)
                }
            }
            // Below the work rows: the day's talk time must never cost the fold.
            if let voices = state.todayVoices, HomeWhoSpokeToday.isShown(voices) {
                HomeWhoSpokeToday(
                    voices: voices,
                    onOpenMeeting: { route = .meeting($0) },
                    onOpenEvent: { perform(.openBrief($0)) },
                    // Per minute, never per caption: a live strip changes with every one.
                    onMinute: { if HomeWhoSpokeToday.isStale(voices, at: Date()) { perform(.loadTodayVoices) } })
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                headerTitle
                Spacer(minLength: PVDesign.space4)
                headerTools
            }
            VStack(alignment: .leading, spacing: PVDesign.space3) {
                headerTitle
                headerTools
            }
        }
    }

    private var headerTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Today")
                .font(.body.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home-title")
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .foregroundStyle(PVDesign.ink3)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var headerTools: some View {
        HStack(spacing: 14) {
            HomeAskField(suggestions: Self.suggestedQuestions, onAsk: onAsk)
                .frame(minWidth: 240, maxWidth: 330)
            if state.pendingAutomations > 0 {
                Button(action: onOpenAutomations) {
                    Label(
                        L10n.format("Automations · %d to review", state.pendingAutomations),
                        systemImage: PVSymbol.automations)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(PVDesign.green)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(PVDesign.greenBg, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Review the automations Portavoz suggested from your meetings")
                .accessibilityIdentifier("home-automations")
            }
        }
    }

    // MARK: - Agenda

    private var laterToday: ArraySlice<UpcomingEvent> {
        state.upcomingToday.dropFirst()
    }

    private var tomorrow: ArraySlice<UpcomingEvent> {
        state.upcomingTomorrow
            .dropFirst(state.heroEvent?.isToday == false ? 1 : 0)
            .prefix(Self.maximumTomorrowEvents)
    }

    @ViewBuilder
    private func agendaSection(_ page: TodayPageCast) -> some View {
        let hasLater = !laterToday.isEmpty || !tomorrow.isEmpty
        // Laid out from the hero alone, so the card arriving never moves the countdown.
        if state.heroEvent == nil, !hasLater {
            hero(page)
        } else {
            HomeAgendaSection {
                hero(page)
            } side: { isWide in
                VStack(alignment: .leading, spacing: PVDesign.space4) {
                    // Stacked, an empty brief only pushes open work below the fold.
                    if let briefPreview = state.heroBriefPreview, isWide || briefPreview.hasLines {
                        briefCard(briefPreview, page: page)
                    }
                    if hasLater { laterCard }
                }
            }
        }
    }

    @ViewBuilder
    private func hero(_ page: TodayPageCast) -> some View {
        if let next = state.heroEvent, let cast = page.hero {
            let event = next.event
            HomeNextMeetingHero(
                event: event,
                cast: cast,
                isToday: next.isToday,
                recordingActive: recordingActive,
                briefLoading: state.briefLoading,
                onRecord: { route = .recording(event) },
                onBrief: { perform(.openBrief(event)) },
                onEnded: { perform(.refreshAgenda) })
        } else {
            emptyHero
        }
    }

    /// No meeting ahead: the calendar offer or a plain line, and recording
    /// stays one click away.
    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: PVDesign.space3) {
            HomeHeroKicker(lead: L10n.text("Next meeting"), leadTint: PVDesign.ink3)
            if state.offerCalendar {
                Button {
                    perform(.requestCalendarAccess)
                } label: {
                    Label("Connect your calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.pvSecondary)
                .accessibilityIdentifier("home-calendar-offer")
                // The help text is one catalog key; keep the sentence whole.
                .help("Shows today's and tomorrow's meetings with a brief for each.")
            } else {
                Text("Nothing scheduled — record when the call starts.")
                    .font(.title3)
                    .foregroundStyle(PVDesign.ink2)
            }
            Button(action: onRecord) {
                RecordLabel(recordingActive ? "Return to recording" : "Record now")
            }
            .buttonStyle(.pvPrimary)
            .controlSize(.large)
            .keyboardShortcut("r")
            .accessibilityIdentifier("home-record")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var laterCard: some View {
        let heroIsToday = state.heroEvent?.isToday ?? true
        return card(title: heroIsToday ? L10n.text("Later today") : L10n.text("Tomorrow")) {
            if !laterToday.isEmpty {
                ForEach(laterToday) { event in
                    agendaRow(event)
                }
            } else if !state.upcomingToday.isEmpty {
                emptyLine("Nothing else scheduled today.")
            }
            if heroIsToday, !tomorrow.isEmpty {
                Text("Tomorrow")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PVDesign.ink3)
                    .padding(.top, 4)
            }
            ForEach(tomorrow) { event in
                agendaRow(event)
            }
        }
    }

    private func agendaRow(_ event: UpcomingEvent) -> some View {
        HStack(spacing: PVDesign.space2) {
            Text(event.startDate, format: .dateTime.hour().minute())
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !event.attendees.isEmpty {
                    Text(event.attendees.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(PVDesign.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                perform(.openBrief(event))
            } label: {
                if state.briefLoading == event {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Brief", systemImage: "doc.text")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.pvSecondary)
            .controlSize(.small)
            .disabled(state.briefLoading != nil)
            .help("See who's coming, related meetings and open to-dos")
            .accessibilityLabel(L10n.text("Brief"))
            .accessibilityIdentifier("home-upcoming-brief-\(event.id)")
            Button {
                route = .recording(event)
            } label: {
                RecordDot()
            }
            .buttonStyle(.pvSecondary)
            .controlSize(.small)
            .help("Starts recording linked to this event: the meeting gets its real title")
            .accessibilityLabel(L10n.text("Record"))
            .accessibilityIdentifier("home-upcoming-record-\(event.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-upcoming-\(event.id)")
    }

    // MARK: - Work

    private func yoursToDo(_ page: TodayPageCast) -> some View {
        HomeYoursToDo(
            items: state.shownOpenItems,
            totalOpen: state.openItems.count,
            sources: state.openItemSources,
            page: page,
            suggestionsToReview: state.suggestionsToReview,
            onToggle: { perform(.setActionItem($0, done: $1)) },
            onOpen: onOpenMeeting,
            onOpenRadar: { route = .commitments(nil) })
    }

    private func pickUp(_ rows: [TodayPickUp.Row], page: TodayPageCast) -> some View {
        HomePickUp(
            rows: rows,
            hasMeetings: !state.meetings.isEmpty,
            page: page,
            openItems: state.openItems,
            onOpen: { route = .meeting($0) })
    }

    // MARK: - Chrome

    private func card<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PVDesign.space2) {
            Text(title)
                .pvDisplay(.section)
            content()
        }
        .padding(PVDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PVDesign.radiusCard))
    }

    private func emptyLine(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.ink3)
    }

    private func perform(_ action: LibraryModel.Action) {
        Task { _ = await model.send(action) }
    }
}

private extension HomeView {
    /// Speaker fixes in a to-do's meeting rename who said it.
    struct TodayWorkTrigger: Equatable {
        /// Leaves loading once both sections arrived, whichever came last.
        let loadPhase: LibraryModel.LoadPhase
        let revision: Int
        let sourceStrips: [VoiceStripColumns?]
    }

    /// The source's strip follows speaker fixes in that meeting.
    struct BriefPreviewTrigger: Equatable {
        let event: UpcomingEvent?
        let revision: Int
        let sourceStrip: VoiceStripColumns?
    }

    func briefCard(_ preview: LibraryModel.BriefPreview, page: TodayPageCast) -> some View {
        let sourceID = preview.lines?.sourceMeetingID
        return HomeBriefCard(
            preview: preview,
            source: sourceID.flatMap { id in state.meetings.first { $0.id == id } },
            page: page,
            briefDisabled: state.briefLoading != nil,
            onBrief: { state.heroEvent.map { perform(.openBrief($0.event)) } },
            onOpenLine: onOpenMeeting)
    }
}
