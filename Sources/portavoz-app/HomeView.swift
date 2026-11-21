import ApplicationKit
import PortavozCore
import SwiftUI

/// The default destination: one screen for someone who lives in calls.
///
/// Everything a day needs sits above the fold and reads from the Library
/// snapshot that the sidebar already observes — the next meeting as the
/// hero, the rest of the agenda, the to-dos still open, and the meetings to
/// pick back up. It renders the Library snapshot and sends the same actions
/// the sidebar sends.
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

    // Sized so the hero, open work and recent meetings land above the fold
    // at the default window height.
    private static let maximumOpenItems = 5
    private static let maximumRecentMeetings = 3
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
            if state == .key { perform(.refreshAutomations) }
        }
        // Re-read on library changes, so edits to the previous meeting show.
        .onChange(
            of: BriefPreviewTrigger(
                event: state.heroEvent?.event, revision: state.libraryRevision,
                sourceStrip: state.briefPreview?.lines.flatMap { state.voiceStrips[$0.sourceMeetingID] }),
            initial: true
        ) { _, trigger in
            if let event = trigger.event { perform(.loadBriefPreview(event)) }
        }
    }

    /// Header, the next meeting as the hero beside the rest of the agenda,
    /// then open work beside the meetings to pick up.
    private var content: some View {
        VStack(alignment: .leading, spacing: PVDesign.space4) {
            header
            agendaSection
            Divider().padding(.vertical, PVDesign.space1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PVDesign.space4) {
                    openWorkCard.frame(maxWidth: .infinity, alignment: .topLeading)
                    recentCard.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: PVDesign.space4) {
                    openWorkCard
                    recentCard
                }
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
    private var agendaSection: some View {
        let hasLater = !laterToday.isEmpty || !tomorrow.isEmpty
        // Laid out from the hero alone, so the card arriving never moves the countdown.
        if state.heroEvent == nil, !hasLater {
            hero
        } else {
            HomeAgendaSection {
                hero
            } side: { isWide in
                VStack(alignment: .leading, spacing: PVDesign.space4) {
                    // Stacked, an empty brief only pushes open work below the fold.
                    if let briefPreview, isWide || briefPreview.hasLines { briefCard(briefPreview) }
                    if hasLater { laterCard }
                }
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let next = state.heroEvent {
            let event = next.event
            HomeNextMeetingHero(
                event: event,
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

    // MARK: - Open work

    private var openWorkCard: some View {
        card(
            title: L10n.text("Open to-dos"),
            trailing: state.openItems.count > Self.maximumOpenItems
                ? L10n.format("%d more in Radar", state.openItems.count - Self.maximumOpenItems)
                : nil,
            trailingAction: { route = .commitments(nil) },
            content: {
                if state.openItems.isEmpty {
                    emptyLine("All caught up — nothing open.")
                } else {
                    ForEach(state.openItems.prefix(Self.maximumOpenItems)) { open in
                        openItemRow(open)
                    }
                }
            })
    }

    private func openItemRow(_ open: LibraryOpenItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PVDesign.space2) {
            Toggle(isOn: Binding(
                get: { open.item.isDone },
                set: { perform(.setActionItem(open.item.id, done: $0)) }
            )) { EmptyView() }
                .toggleStyle(.pvCheckbox)
                .labelsHidden()
                .accessibilityLabel(Text(open.item.text))
                .accessibilityIdentifier("home-todo-toggle-\(open.id.uuidString)")
            Button {
                route = .meeting(open.meetingID)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(open.item.text).lineLimit(2)
                    Text(MeetingRowTitle.display(open.meetingTitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the meeting this to-do came from")
            .accessibilityIdentifier("home-todo-\(open.id.uuidString)")
        }
    }

    // MARK: - Recent meetings

    private var recentCard: some View {
        let openByMeeting = Dictionary(grouping: state.openItems, by: \.meetingID)
            .mapValues(\.count)
        return card(title: L10n.text("Pick up where you left off")) {
            if state.meetings.isEmpty {
                emptyLine("No meetings yet")
            } else {
                ForEach(state.meetings.prefix(Self.maximumRecentMeetings)) { meeting in
                    recentRow(meeting, openCount: openByMeeting[meeting.id] ?? 0)
                }
            }
        }
    }

    private func recentRow(_ meeting: Meeting, openCount: Int) -> some View {
        Button {
            route = .meeting(meeting.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: PVDesign.space3) {
                // The row button would read the strip's label before the title.
                VoiceStrip(state.voiceStrips[meeting.id] ?? .empty)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingRowTitle.display(meeting.title))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(meeting.startedAt, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let minutes = meeting.durationMinutes {
                    Text(L10n.format("%d min", minutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if openCount > 0 {
                    Text(L10n.format("%d open", openCount))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PVDesign.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(PVDesign.ink.opacity(PVDesign.offerTint), in: Capsule())
                }
                lifecycleBadge(meeting.lifecycleState)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-recent-\(meeting.id.rawValue.uuidString)")
    }

    @ViewBuilder
    private func lifecycleBadge(_ lifecycle: MeetingLifecycleState) -> some View {
        switch lifecycle {
        case .processing, .captured:
            Label("Processing", systemImage: "gearshape.2")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsAttention:
            Label("Needs attention", systemImage: PVSymbol.warning)
                .font(.caption)
                .foregroundStyle(PVDesign.caution)
        case .recording, .ready:
            EmptyView()
        }
    }

    // MARK: - Chrome

    private func card<Content: View>(
        title: String,
        trailing: String? = nil,
        trailingAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PVDesign.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .pvDisplay(.section)
                Spacer(minLength: 0)
                if let trailing, let trailingAction {
                    Button(trailing, action: trailingAction)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            content()
        }
        .padding(PVDesign.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PVDesign.radiusCard))
    }

    private func emptyLine(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func perform(_ action: LibraryModel.Action) {
        Task { _ = await model.send(action) }
    }
}

private extension HomeView {
    /// The source's strip follows speaker fixes in that meeting.
    struct BriefPreviewTrigger: Equatable {
        let event: UpcomingEvent?
        let revision: Int
        let sourceStrip: VoiceStripColumns?
    }

    /// Shown once the hero's own occurrence has loaded.
    var briefPreview: LibraryModel.BriefPreview? {
        guard let event = state.heroEvent?.event, let preview = state.briefPreview, preview.isFor(event)
        else { return nil }
        return preview
    }

    func briefCard(_ preview: LibraryModel.BriefPreview) -> some View {
        let sourceID = preview.lines?.sourceMeetingID
        return HomeBriefCard(
            preview: preview,
            source: sourceID.flatMap { id in state.meetings.first { $0.id == id } },
            strip: sourceID.flatMap { state.voiceStrips[$0] } ?? .empty,
            briefDisabled: state.briefLoading != nil,
            onBrief: { state.heroEvent.map { perform(.openBrief($0.event)) } },
            onOpenLine: onOpenMeeting)
    }
}

extension Meeting {
    var durationMinutes: Int? {
        guard let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }
}
