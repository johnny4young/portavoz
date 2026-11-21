import ApplicationKit
import PortavozCore
import SwiftUI

/// Today's lower half: how long each person spoke across today's meetings,
/// then the day as an hour axis with every recorded and upcoming meeting.
struct HomeWhoSpokeToday: View {
    let voices: TodayVoices
    let onOpenMeeting: (MeetingID) -> Void
    let onOpenEvent: (UpcomingEvent) -> Void
    let onMinute: () -> Void

    /// You plus the four who spoke most; the rest stay in each meeting's strip.
    static let maximumTalkers = 5

    /// Something happened or is still ahead today.
    nonisolated static func isShown(_ voices: TodayVoices) -> Bool {
        !voices.recorded.isEmpty || !voices.upcoming.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(PVDesign.line2).frame(height: 1)
            header
                .padding(.top, 14)
                .padding(.bottom, 12)
            if !voices.talkers.isEmpty {
                Rectangle().fill(PVDesign.line).frame(height: 1)
                talkers.padding(.top, 12)
            }
            TimelineView(.everyMinute) { context in
                HomeDayAxis(
                    voices: voices, now: context.date, onOpenMeeting: onOpenMeeting, onOpenEvent: onOpenEvent)
                    .onChange(of: context.date) { onMinute() }
            }
            .padding(.top, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-who-spoke")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Who spoke today")
                .pvDisplay(.section)
                .accessibilityAddTraits(.isHeader)
            if let summary = Self.summary(voices) {
                Text(summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(PVDesign.ink3)
                    .accessibilityIdentifier("home-who-spoke-summary")
            }
        }
        .lineLimit(1)
    }

    /// Five equal columns when they fit, three per row otherwise.
    private var talkers: some View {
        let shown = Array(voices.talkers.prefix(Self.maximumTalkers))
        let longest = shown.map(\.talkSeconds).max() ?? 0
        let columns = ForEach(shown) { HomeTalkerColumn(talker: $0, longest: longest) }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 26) { columns }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 26, alignment: .top), count: 3),
                alignment: .leading, spacing: 14
            ) { columns }
        }
    }

    /// A recording grows, and an event starting or ending changes "to go" and
    /// the axis without touching the agenda the model watches.
    nonisolated static func isStale(_ voices: TodayVoices, at now: Date) -> Bool {
        now >= voices.day.end
            || voices.recorded.contains(where: \.isRecording)
            || voices.upcoming.count { $0.event.startDate > now } != voices.toGo
            || voices.upcoming.contains { ($0.event.endDate ?? $0.event.startDate) <= now }
    }

    /// "3 meetings recorded · 1 h 46 min · 2 to go", keeping only what applies.
    nonisolated static func summary(_ voices: TodayVoices) -> String? {
        var parts: [String] = []
        if !voices.recorded.isEmpty {
            parts.append(voices.recorded.count == 1
                ? L10n.text("1 meeting recorded")
                : L10n.format("%d meetings recorded", voices.recorded.count))
            parts.append(TalkDuration.text(voices.recordedSeconds))
        }
        if voices.toGo > 0 { parts.append(L10n.format("%d to go", voices.toGo)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One person: dot, name and minutes, a bar against today's longest talker,
/// and where they spoke.
struct HomeTalkerColumn: View {
    let talker: TodayVoices.Talker
    let longest: TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                VoiceDot(tint: talker.tint, size: 10)
                Text(Self.name(talker))
                    .font(.body.weight(.bold))
                    .foregroundStyle(PVDesign.ink)
                Spacer(minLength: PVDesign.space2)
                Text(TalkDuration.text(talker.talkSeconds))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PVDesign.ink)
                    .layoutPriority(1)
            }
            Capsule()
                .fill(PVDesign.line)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(VoicePalette.color(talker.tint, colorScheme: colorScheme))
                            .frame(width: proxy.size.width * Self.fill(talker, longest: longest))
                    }
                }
                .padding(.top, 7)
            Text(Self.caption(talker))
                .font(.subheadline)
                .foregroundStyle(PVDesign.ink3)
                .padding(.top, 5)
        }
        .lineLimit(1)
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [
            Self.name(talker), TalkDuration.text(talker.talkSeconds), Self.caption(talker)
        ].joined(separator: ", ")))
        .accessibilityIdentifier("home-talker-\(talker.identity.key)")
    }

    nonisolated static func name(_ talker: TodayVoices.Talker) -> String {
        VoiceName.of(isMe: talker.isMe, name: talker.name, label: talker.label)
    }

    /// Share of today's longest talker, so the leader fills the track.
    nonisolated static func fill(_ talker: TodayVoices.Talker, longest: TimeInterval) -> CGFloat {
        guard longest > 0 else { return 0 }
        return CGFloat(min(1, max(0, talker.talkSeconds / longest)))
    }

    /// Unnamed first, because naming is what the person can do about it.
    nonisolated static func caption(_ talker: TodayVoices.Talker) -> String {
        if talker.isUnnamed { return L10n.text("not named yet") }
        if talker.meetings.count == 1, let meeting = talker.meetings.first {
            return MeetingRowTitle.display(meeting.title)
        }
        return L10n.format("%d meetings", talker.meetings.count)
    }
}
