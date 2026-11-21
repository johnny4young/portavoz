import ApplicationKit
import PortavozCore
import SwiftUI

/// What the hero numeral shows at one instant. Pure, so the switch to "now"
/// at the start time is testable without a clock.
enum NextMeetingCountdown: Equatable {
    enum Unit: Equatable { case minutes, hours }

    /// `lead` is the larger unit in ink, `trail` the smaller one after it.
    case counting(lead: String, trail: String, unit: Unit)
    case now

    /// Seconds count up to the start (00:01 until it begins); past an hour the
    /// display drops to whole minutes, so it only changes on a minute boundary.
    init(start: Date, at now: Date, locale: Locale? = nil) {
        let remaining = start.timeIntervalSince(now)
        let seconds = Int(remaining.rounded(.up))
        if seconds <= 0 {
            self = .now
        } else if seconds <= 3_600 {
            self = .counting(
                lead: String(format: "%02d", locale: locale, seconds / 60),
                trail: String(format: ":%02d", locale: locale, seconds % 60),
                unit: .minutes)
        } else {
            // Rounded up like the seconds, so a tick on a boundary shows the minute it starts.
            let minutes = (seconds - 1) / 60
            self = .counting(
                lead: String(format: "%d", locale: locale, minutes / 60),
                trail: String(format: ":%02d", locale: locale, minutes % 60),
                unit: .hours)
        }
    }
}

/// Ticks when the countdown's display can change: each minute while more than
/// an hour remains, each second in the last hour, and once at the start.
struct CountdownSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, start: start)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let start: Date

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            let remaining = start.timeIntervalSince(current)
            if remaining <= 0 {
                upcoming = nil
            } else {
                let step: TimeInterval = remaining > 3_600 ? 60 : 1
                let ticksLeft = (remaining / step).rounded(.up) - 1
                upcoming = start.addingTimeInterval(-ticksLeft * step)
            }
            return current
        }
    }
}

/// The next meeting as the page hero: when it starts, a large countdown,
/// who is invited, how it runs, and the two things to do about it.
struct HomeNextMeetingHero: View {
    let event: UpcomingEvent
    let isToday: Bool
    let recordingActive: Bool
    /// The event whose brief is being prepared, if any.
    let briefLoading: UpcomingEvent?
    let onRecord: () -> Void
    let onBrief: () -> Void
    /// Called once the event's end passes, so the agenda can drop it.
    let onEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isToday {
                HomeCountdown(start: event.startDate)
            } else {
                HomeHeroKicker(
                    lead: L10n.text("Next meeting"),
                    detail: L10n.format(
                        "Tomorrow · %@",
                        event.startDate.formatted(.dateTime.hour().minute())))
            }
            Text(event.title)
                .pvDisplay(.title)
                .lineLimit(2)
                .padding(.top, isToday ? 14 : PVDesign.space2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PVDesign.space4) { details }
                VStack(alignment: .leading, spacing: PVDesign.space2) { details }
            }
            .padding(.top, PVDesign.space3)
            HStack(spacing: 10) {
                Button(action: onRecord) {
                    RecordLabel(recordingActive ? "Return to recording" : "Record")
                }
                .buttonStyle(.pvPrimary)
                .controlSize(.large)
                .keyboardShortcut("r")
                .help("Starts recording linked to this event: the meeting gets its real title")
                .accessibilityIdentifier("home-upcoming-record-\(event.id)")
                Button(action: onBrief) {
                    if briefLoading == event {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open brief", systemImage: "doc.text")
                    }
                }
                .buttonStyle(.pvSecondary)
                .controlSize(.large)
                .disabled(briefLoading != nil)
                .help("See who's coming, related meetings and open to-dos")
                .accessibilityIdentifier("home-upcoming-brief-\(event.id)")
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-upcoming-\(event.id)")
        .task(id: event.endDate) {
            guard let end = event.endDate else { return }
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            onEnded()
        }
    }

    @ViewBuilder
    private var details: some View {
        let cast = Self.inviteeCast(event.attendees)
        if !event.attendees.isEmpty {
            HStack(spacing: PVDesign.space4) {
                ForEach(cast.voices) { voice in
                    HomeInvitee(voice: voice)
                }
                if !cast.others.isEmpty {
                    Text(L10n.format("Others · %d", cast.others.count))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PVDesign.ink2)
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home-upcoming-invitees")
        }
        if let facts = Self.facts(event) {
            HStack(spacing: PVDesign.space4) {
                if !event.attendees.isEmpty {
                    Rectangle()
                        .fill(PVDesign.line2)
                        .frame(width: 1, height: 14)
                        .accessibilityHidden(true)
                }
                Text(facts)
                    .font(.body)
                    .foregroundStyle(PVDesign.ink2)
                    .lineLimit(1)
            }
        }
    }

    /// Invitees in calendar order with you last; colour follows the same
    /// cast rule as a recorded meeting, so a name keeps its hue.
    nonisolated static func inviteeCast(_ attendees: [String]) -> VoiceCast {
        let members = attendees.enumerated().map { index, name in
            VoiceCast.Member(key: "invitee-\(index)", name: name, talkSeconds: 0)
        } + [VoiceCast.Member(key: "me", isMe: true, name: nil, talkSeconds: 0)]
        return VoiceCast(members: members, ordering: .talkShare)
    }

    /// Platform · duration · recurrence, keeping only what the calendar gave.
    nonisolated static func facts(_ event: UpcomingEvent) -> String? {
        let parts = [
            event.platform?.displayName,
            event.durationMinutes.map { L10n.format("%d min", $0) },
            event.recurrence.map { L10n.text($0.rawValue) }
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct HomeInvitee: View {
    let voice: VoiceCast.Voice
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(VoicePalette.color(voice.tint, colorScheme: colorScheme))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(voice.isMe ? L10n.text("You") : voice.name ?? "")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(PVDesign.ink)
        }
    }
}

/// The two-part uppercase line above the numeral.
struct HomeHeroKicker: View {
    let lead: String
    var detail: String?
    var leadTint: Color = PVDesign.ink

    var body: some View {
        HStack(spacing: 9) {
            Text(lead).foregroundStyle(leadTint)
            if let detail {
                Text(detail).foregroundStyle(PVDesign.ink3)
            }
        }
        .font(.caption2.weight(.semibold))
        .tracking(1.3)
        .textCase(.uppercase)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Only this view re-renders every second. Digits sit in equal cells, so the
/// numeral keeps its width while it counts and nothing around it moves.
private struct HomeCountdown: View {
    let start: Date

    var body: some View {
        let locale = AppLanguage.current.locale
        TimelineView(CountdownSchedule(start: start)) { context in
            let countdown = NextMeetingCountdown(start: start, at: context.date, locale: locale)
            VStack(alignment: .leading, spacing: 0) {
                kicker(countdown)
                numeral(countdown)
                    .padding(.leading, -8)
                    .padding(.vertical, -26)
                    .padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(countdown))
                    .accessibilityIdentifier("home-upcoming-countdown")
            }
        }
    }

    private var startTime: String {
        start.formatted(.dateTime.hour().minute())
    }

    private func kicker(_ countdown: NextMeetingCountdown) -> some View {
        switch countdown {
        case .counting:
            HomeHeroKicker(
                lead: L10n.text("Next meeting"),
                detail: L10n.format("Starts %@ · in", startTime))
        case .now:
            HomeHeroKicker(
                lead: L10n.text("Now"),
                detail: L10n.format("Started %@", startTime),
                leadTint: PVDesign.now)
        }
    }

    @ViewBuilder
    private func numeral(_ countdown: NextMeetingCountdown) -> some View {
        switch countdown {
        case .counting(let lead, let trail, let unit):
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                DisplayTimeText(lead, style: .countdown)
                    .foregroundStyle(PVDesign.ink)
                DisplayTimeText(trail, style: .countdownTrail)
                    .foregroundStyle(PVDesign.ink3)
                Text(unit == .minutes ? L10n.text("min") : L10n.text("h"))
                    .font(.body.weight(.semibold))
                    .tracking(1.3)
                    .textCase(.uppercase)
                    .foregroundStyle(PVDesign.ink3)
                    .padding(.leading, 14)
            }
            .lineLimit(1)
            .fixedSize()
        case .now:
            Text(L10n.text("Now"))
                .pvDisplay(.countdown)
                .foregroundStyle(PVDesign.now)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func accessibilityLabel(_ countdown: NextMeetingCountdown) -> Text {
        switch countdown {
        case .counting:
            Text(start, format: .relative(presentation: .named))
        case .now:
            Text(L10n.text("Now"))
        }
    }
}

/// The hero beside the brief and the rest of the agenda when there is room, above it
/// otherwise. Chosen from the proposed width alone, so the ticking hero is
/// never measured against alternative layouts. Expects two subviews.
struct HomeHeroLayout: Layout {
    private static let sideWidths: ClosedRange<CGFloat> = 360...552
    private static let minimumHeroWidth: CGFloat = 536
    private static let spacing: CGFloat = 44
    private static let stackedSpacing = PVDesign.space6
    private static let minimumWideWidth = minimumHeroWidth + spacing + sideWidths.lowerBound

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.minimumWideWidth
        let heights = frames(width: width, subviews: subviews).map(\.maxY)
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: nil))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        if width >= Self.minimumWideWidth {
            // The side grows to its full width once the hero keeps its minimum.
            let side = min(Self.sideWidths.upperBound, width - Self.minimumHeroWidth - Self.spacing)
            let heroWidth = width - side - Self.spacing
            return [
                CGRect(origin: .zero, size: size(subviews[0], width: heroWidth)),
                CGRect(origin: CGPoint(x: width - side, y: 0), size: size(subviews[1], width: side))
            ]
        }
        let hero = CGRect(origin: .zero, size: size(subviews[0], width: width))
        let sideY = hero.maxY + Self.stackedSpacing
        return [hero, CGRect(origin: CGPoint(x: 0, y: sideY), size: size(subviews[1], width: width))]
    }

    private func size(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }
}
