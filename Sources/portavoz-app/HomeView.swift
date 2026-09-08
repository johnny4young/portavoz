import ApplicationKit
import PortavozCore
import SwiftUI

/// The default destination: one screen for someone who lives in calls.
///
/// Everything a day needs sits above the fold and reads from the Library
/// snapshot that the sidebar already observes — the agenda with a brief and a
/// linked recording per event, the to-dos still open, the meetings to pick
/// back up, and one-click questions for the Ask surface. No new store,
/// observation, or capability enters this view; it composes values and sends
/// the same actions the sidebar sends.
struct HomeView: View {
    let model: LibraryModel
    @Binding var route: Route?
    let recordingActive: Bool
    let onRecord: () -> Void
    let onAsk: (String?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var state: LibraryModel.State { model.state }

    // Sized so the agenda, open work, recent meetings and the question chips
    // all land above the fold at the default window height.
    private static let maximumOpenItems = 5
    private static let maximumRecentMeetings = 3

    /// Suggested questions: the ones a daily user types most, ready to send.
    private static let suggestedQuestions: [String] = [
        "What did I commit to this week?",
        "Which decisions were made this week?",
        "What is still open?",
        "Who did I talk with recently?"
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .padding(PVDesign.space6)
                    .frame(maxWidth: 1100, alignment: .topLeading)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
            }
        }
        .navigationTitle("Portavoz")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PVDesign.space4) {
            header
            statStrip
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: PVDesign.space4) {
                    agendaCard.frame(maxWidth: .infinity, alignment: .topLeading)
                    openWorkCard.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: PVDesign.space4) {
                    agendaCard
                    openWorkCard
                }
            }
            recentCard
            askCard
            Label("Local-first · transfers require opt-in", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PVDesign.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityIdentifier("home-title")
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onRecord) {
                Label(
                    recordingActive ? LocalizedStringKey("Return to recording") : LocalizedStringKey("New recording"),
                    systemImage: recordingActive ? "record.circle" : "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("home-record")
            Button {
                onAsk(nil)
            } label: {
                Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("home-ask")
        }
    }

    // MARK: - Stats

    private var weekFacts: HomeWeekFacts {
        HomeWeekFacts(meetings: state.meetings, openItemCount: state.openItems.count)
    }

    private var statStrip: some View {
        let facts = weekFacts
        return HStack(spacing: PVDesign.space3) {
            statTile(
                value: "\(facts.meetingCount)",
                label: L10n.text("meetings this week"),
                symbol: "waveform",
                id: "home-stat-meetings")
            statTile(
                value: facts.recordedLabel,
                label: L10n.text("recorded this week"),
                symbol: "clock",
                id: "home-stat-recorded")
            statTile(
                value: "\(facts.openItemCount)",
                label: L10n.text("open to-dos"),
                symbol: "checklist",
                tint: facts.openItemCount > 0 ? PVDesign.brandAmber : nil,
                id: "home-stat-open")
        }
    }

    private func statTile(
        value: String, label: String, symbol: String, tint: Color? = nil, id: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint ?? PVDesign.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title2.bold().monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(PVDesign.space3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PVDesign.radiusTile))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: - Agenda

    private var agendaCard: some View {
        card(title: L10n.text("Up next"), symbol: "calendar.badge.clock") {
            if state.upcomingToday.isEmpty, state.upcomingTomorrow.isEmpty {
                if state.offerCalendar {
                    Button {
                        perform(.requestCalendarAccess)
                    } label: {
                        Label("Connect your calendar", systemImage: "calendar.badge.plus")
                    }
                    .accessibilityIdentifier("home-calendar-offer")
                    // The help text is one catalog key; keep the sentence whole.
                    // swiftlint:disable:next line_length
                    .help("Shows today's and tomorrow's meetings here, with a prep brief for each. Read-only, on-device.")
                } else {
                    emptyLine("Nothing scheduled — record when the call starts.")
                }
            } else {
                ForEach(Array(state.upcomingToday.enumerated()), id: \.element.id) { index, event in
                    agendaRow(event, isNext: index == 0)
                }
                if state.upcomingToday.isEmpty {
                    emptyLine("Nothing else scheduled today.")
                }
                if !state.upcomingTomorrow.isEmpty {
                    Text("Tomorrow")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(state.upcomingTomorrow.prefix(3)) { event in
                        agendaRow(event, isNext: false)
                    }
                }
            }
        }
    }

    /// `isNext` is the first row of today — a positional fact, so the emphasis
    /// never goes stale. The countdown reads "in 45 minutes" rather than a
    /// ticking clock; the agenda refresh the sidebar already runs keeps it
    /// current, and a glance never has to watch seconds count down.
    private func agendaRow(_ event: UpcomingEvent, isNext: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PVDesign.space2) {
            Text(event.startDate, format: .dateTime.hour().minute())
                .font(.callout.monospacedDigit().weight(isNext ? .semibold : .medium))
                .foregroundStyle(PVDesign.accent)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body.weight(isNext ? .semibold : .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isNext {
                        Text(event.startDate, format: .relative(presentation: .named))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(PVDesign.accent)
                            .accessibilityIdentifier("home-upcoming-countdown")
                    }
                    if !event.attendees.isEmpty {
                        Text(event.attendees.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                perform(.openBrief(event))
            } label: {
                if state.briefLoading == event {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Brief", systemImage: "doc.text.magnifyingglass")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.briefLoading != nil)
            .help("Brief for this meeting: who's coming, related meetings, open to-dos")
            .accessibilityIdentifier("home-upcoming-brief-\(event.id)")
            Button {
                route = .recording(event)
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(PVDesign.accent)
            .help("Starts recording linked to this event: the meeting gets its real title")
            .accessibilityIdentifier("home-upcoming-record-\(event.id)")
        }
        .padding(.vertical, isNext ? 6 : 0)
        .padding(.horizontal, isNext ? 8 : 0)
        .background(
            isNext ? PVDesign.accent.opacity(PVDesign.offerTint) : .clear,
            in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-upcoming-\(event.id)")
    }

    // MARK: - Open work

    private var openWorkCard: some View {
        card(
            title: L10n.text("Open to-dos"),
            symbol: "checklist",
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
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(open.item.text))
                .accessibilityIdentifier("home-todo-toggle-\(open.id.uuidString)")
            Button {
                route = .meeting(open.meetingID)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(open.item.text).lineLimit(2)
                    Text(open.meetingTitle)
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
        return card(title: L10n.text("Pick up where you left off"), symbol: "clock.arrow.circlepath") {
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
                VoiceMixBar(slices: state.voiceMixes[meeting.id] ?? [], colorScheme: colorScheme)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
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
                        .foregroundStyle(PVDesign.amberContrast)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(PVDesign.brandAmber.opacity(0.7), in: Capsule())
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
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(PVDesign.brandAmber)
        case .recording, .ready:
            EmptyView()
        }
    }

    // MARK: - Ask

    private var askCard: some View {
        card(title: L10n.text("Ask your meetings"), symbol: "bubble.left.and.text.bubble.right") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PVDesign.space2) { askChips }
                VStack(alignment: .leading, spacing: PVDesign.space2) { askChips }
            }
        }
    }

    @ViewBuilder
    private var askChips: some View {
        ForEach(Array(Self.suggestedQuestions.enumerated()), id: \.offset) { index, question in
            Button {
                onAsk(L10n.text(question))
            } label: {
                Text(L10n.text(question))
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(PVDesign.accent.opacity(PVDesign.chipTint), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-ask-chip-\(index)")
        }
    }

    // MARK: - Chrome

    private func card<Content: View>(
        title: String,
        symbol: String,
        trailing: String? = nil,
        trailingAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PVDesign.space2) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.headline)
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

/// This week's totals from the Library snapshot — no query, no clock injection
/// beyond the calendar week that contains now.
struct HomeWeekFacts: Equatable {
    let meetingCount: Int
    let recordedSeconds: TimeInterval
    let openItemCount: Int

    init(meetings: [Meeting], openItemCount: Int, now: Date = .now, calendar: Calendar = .current) {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        var count = 0
        var seconds: TimeInterval = 0
        for meeting in meetings where week?.contains(meeting.startedAt) ?? false {
            count += 1
            if let endedAt = meeting.endedAt {
                seconds += max(0, endedAt.timeIntervalSince(meeting.startedAt))
            }
        }
        meetingCount = count
        recordedSeconds = seconds
        self.openItemCount = openItemCount
    }

    /// "48 min" under an hour, "2.3 h" from one hour on.
    var recordedLabel: String {
        let minutes = Int((recordedSeconds / 60).rounded())
        if minutes < 60 { return L10n.format("%d min", minutes) }
        return L10n.format("%@ h", String(format: "%.1f", recordedSeconds / 3_600))
    }
}

private extension Meeting {
    var durationMinutes: Int? {
        guard let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }
}
