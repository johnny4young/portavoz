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
    /// Invitees with you last, in the day's hues when known.
    let cast: VoiceCast
    let isToday: Bool
    /// Steps the countdown down to fit beside the brief in a narrower section.
    var compact = false
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
                HomeCountdown(start: event.startDate, compact: compact)
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
                HStack(spacing: PVDesign.space4) {
                    details { HStack(spacing: PVDesign.space4) { invitees } }
                }
                VStack(alignment: .leading, spacing: PVDesign.space2) {
                    details { FlowLayout(spacing: PVDesign.space4, rowSpacing: 4) { invitees } }
                }
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
    private func details(@ViewBuilder inviteeRow: () -> some View) -> some View {
        if !event.attendees.isEmpty {
            inviteeRow()
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

    @ViewBuilder
    private var invitees: some View {
        ForEach(cast.voices) { voice in
            HomeInvitee(voice: voice)
        }
        if !cast.others.isEmpty {
            Text(L10n.format("Others · %d", cast.others.count))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(PVDesign.ink2)
        }
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
struct HomeCountdown: View {
    let start: Date
    var compact = false

    private var leadStyle: PVDisplayStyle { compact ? .countdownCompact : .countdown }
    private var trailStyle: PVDisplayStyle { compact ? .countdownTrailCompact : .countdownTrail }

    var body: some View {
        let locale = AppLanguage.current.locale
        // The numeral's side bearing and line gap, trimmed in proportion to its size.
        let trim = leadStyle.size / PVDisplayStyle.countdown.size
        TimelineView(CountdownSchedule(start: start)) { context in
            let countdown = NextMeetingCountdown(start: start, at: context.date, locale: locale)
            VStack(alignment: .leading, spacing: 0) {
                kicker(countdown)
                numeral(countdown)
                    .padding(.leading, -8 * trim)
                    .padding(.vertical, -26 * trim)
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
                DisplayTimeText(lead, style: leadStyle)
                    .foregroundStyle(PVDesign.ink)
                DisplayTimeText(trail, style: trailStyle)
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
                .pvDisplay(leadStyle)
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
    enum Arrangement: Equatable {
        /// Beside a hero with the full countdown.
        case wide
        /// Beside a hero whose countdown steps down to fit.
        case compact
        /// Under the hero.
        case stacked

        var isBeside: Bool { self != .stacked }
    }

    private struct Columns {
        let hero: CGFloat
        let side: ClosedRange<CGFloat>
        let spacing: CGFloat
        var minimumWidth: CGFloat { hero + spacing + side.lowerBound }
    }

    // Compact tops out at the wide side's minimum, so crossing into wide keeps the side where it is.
    private static let wide = Columns(hero: 536, side: 360...552, spacing: 44)
    private static let compact = Columns(hero: 324, side: 284...360, spacing: 32)
    private static let stackedSpacing = PVDesign.space6

    static func arrangement(width: CGFloat) -> Arrangement {
        if width >= wide.minimumWidth { return .wide }
        if width >= compact.minimumWidth { return .compact }
        return .stacked
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.wide.minimumWidth
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

    /// Hero and side widths when they sit side by side; nil when stacked.
    static func columns(width: CGFloat) -> (hero: CGFloat, side: CGFloat)? {
        let columns: Columns
        switch arrangement(width: width) {
        case .wide: columns = wide
        case .compact: columns = compact
        case .stacked: return nil
        }
        // The side grows to its full width once the hero keeps its minimum.
        let side = min(columns.side.upperBound, width - columns.hero - columns.spacing)
        return (width - side - columns.spacing, side)
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        guard let columns = Self.columns(width: width) else {
            let hero = CGRect(origin: .zero, size: size(subviews[0], width: width))
            let side = size(subviews[1], width: width)
            // An empty side column adds no gap under the hero.
            let sideY = hero.maxY + (side.height > 0 ? Self.stackedSpacing : 0)
            return [hero, CGRect(origin: CGPoint(x: 0, y: sideY), size: side)]
        }
        return [
            CGRect(origin: .zero, size: size(subviews[0], width: columns.hero)),
            CGRect(origin: CGPoint(x: width - columns.side, y: 0), size: size(subviews[1], width: columns.side))
        ]
    }

    private func size(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }
}

/// The agenda in `HomeHeroLayout`, telling the hero and the side column which
/// arrangement they are in. Owns that one value so `HomeView` keeps no state of its own.
struct HomeAgendaSection<Hero: View, Side: View>: View {
    @ViewBuilder let hero: (_ arrangement: HomeHeroLayout.Arrangement) -> Hero
    @ViewBuilder let side: (_ arrangement: HomeHeroLayout.Arrangement) -> Side
    @State private var arrangement = HomeHeroLayout.Arrangement.stacked

    var body: some View {
        HomeHeroLayout {
            hero(arrangement)
            side(arrangement)
        }
        // The section's width comes from the window alone, never from its content.
        .onGeometryChange(for: HomeHeroLayout.Arrangement.self) { proxy in
            HomeHeroLayout.arrangement(width: proxy.size.width)
        } action: { arrangement = $0 }
    }
}
