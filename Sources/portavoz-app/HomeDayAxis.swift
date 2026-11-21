import ApplicationKit
import PortavozCore
import SwiftUI

/// "44 min" / "1 h 5 min" in whole minutes; anything above zero shows at
/// least one minute.
enum TalkDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let minutes = seconds > 0 ? max(1, Int((seconds / 60).rounded())) : 0
        guard minutes >= 60 else { return L10n.format("%d min", minutes) }
        return L10n.format("%d h %d min", minutes / 60, minutes % 60)
    }
}

/// Where everything on the day axis sits: the padded range, the hour ruler,
/// the now line and each meeting's frame.
struct DayAxisLayout: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let start: Date
        let end: Date

        init(start: Date, end: Date) {
            self.start = start
            self.end = max(start, end)
        }

        init(start: Date, duration: TimeInterval) {
            self.init(start: start, end: start.addingTimeInterval(duration))
        }
    }

    struct Tick: Sendable, Equatable {
        let date: Date
        let x: CGFloat
        let labeled: Bool
    }

    struct Frame: Sendable, Equatable {
        let x: CGFloat
        let width: CGFloat
        /// Room for the title before the next meeting or the now pill.
        let titleWidth: CGFloat
    }

    static let pad: TimeInterval = 30 * 60
    static let minimumSpan: TimeInterval = 5 * 3_600
    static let titleGap: CGFloat = 10
    /// Half the now pill, which sits over the titles.
    static let nowClearance: CGFloat = 40
    static let minimumRecordedWidth: CGFloat = 4
    static let minimumUpcomingWidth: CGFloat = 12

    let axisStart: Date
    let axisEnd: Date
    let width: CGFloat
    let ticks: [Tick]
    /// Nil when now falls outside the axis.
    let nowX: CGFloat?
    let recorded: [Frame]
    let upcoming: [Frame]

    init(
        day: DateInterval, now: Date, recorded: [Item], upcoming: [Item], width: CGFloat,
        calendar: Calendar
    ) {
        let items = recorded + upcoming
        let lower = max(day.start, items.map(\.start).reduce(now, min))
        let upper = max(lower, items.map(\.end).reduce(now, max))
        let start = Self.hour(lower, roundingUp: false, calendar: calendar).addingTimeInterval(-Self.pad)
        let end = Self.hour(upper, roundingUp: true, calendar: calendar).addingTimeInterval(Self.pad)
        axisStart = start
        axisEnd = max(end, start.addingTimeInterval(Self.minimumSpan))
        self.width = max(0, width)

        let scale = self.width / axisEnd.timeIntervalSince(axisStart)
        func position(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(start)) * scale
        }

        let pointsPerHour = 3_600 * scale
        let stride = pointsPerHour >= 56 ? 1 : pointsPerHour >= 28 ? 2 : 3
        let firstHour = start.addingTimeInterval(Self.pad)
        let hours = Int(axisEnd.timeIntervalSince(firstHour) / 3_600)
        ticks = (0...max(0, hours)).map { index in
            let date = firstHour.addingTimeInterval(TimeInterval(index) * 3_600)
            return Tick(date: date, x: position(date), labeled: index.isMultiple(of: stride))
        }

        let nowX = (start...axisEnd).contains(now) ? position(now) : nil
        self.nowX = nowX

        let edges = items.map { max(0, position($0.start)) }
        let total = self.width
        func frames(_ items: [Item], offset: Int, minimumWidth: CGFloat) -> [Frame] {
            items.enumerated().map { index, item in
                let x = max(0, position(item.start))
                var limit = edges.filter { $0 > x }.min().map { $0 - Self.titleGap } ?? total
                // Meetings sharing a start would print one title over the other; the first keeps it.
                if edges.prefix(offset + index).contains(x) { limit = x }
                if let nowX, item.start < now { limit = min(limit, nowX - Self.nowClearance) }
                return Frame(
                    x: x,
                    width: max(minimumWidth, position(item.end) - x),
                    titleWidth: max(0, limit - x))
            }
        }
        self.recorded = frames(recorded, offset: 0, minimumWidth: Self.minimumRecordedWidth)
        self.upcoming = frames(upcoming, offset: recorded.count, minimumWidth: Self.minimumUpcomingWidth)
    }

    func x(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(axisStart) / axisEnd.timeIntervalSince(axisStart)) * width
    }

    private static func hour(_ date: Date, roundingUp: Bool, calendar: Calendar) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return date }
        return roundingUp && hour.start < date ? hour.end : hour.start
    }
}

/// Today's meetings on one line: recorded ones as voice strips at their real
/// time and length, the ones to come as outlines, and now between them.
struct HomeDayAxis: View {
    let voices: TodayVoices
    let now: Date
    let onOpenMeeting: (MeetingID) -> Void
    let onOpenEvent: (UpcomingEvent) -> Void

    private static let height: CGFloat = 96
    private static let titleY: CGFloat = 10
    private static let stripY: CGFloat = 39
    private static let stripHeight: CGFloat = 10
    private static let baselineY = stripY + stripHeight / 2
    private static let dotsY: CGFloat = 55
    private static let dot: CGFloat = 7
    /// Tall enough for the title, the strip and the dots under it.
    private static let itemHeight: CGFloat = 68

    var body: some View {
        GeometryReader { proxy in
            axis(width: proxy.size.width)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-day-axis")
    }

    private var locale: Locale { AppLanguage.current.locale }

    private func axis(width: CGFloat) -> some View {
        let layout = DayAxisLayout(
            day: voices.day,
            now: now,
            recorded: voices.recorded.map { .init(start: $0.startedAt, duration: $0.duration) },
            upcoming: voices.upcoming.map {
                .init(start: $0.event.startDate, end: $0.event.endDate ?? $0.event.startDate + DayAxisLayout.pad)
            },
            width: width,
            calendar: .current)
        let next = voices.upcoming.first { $0.event.startDate > now }?.id
        return ZStack(alignment: .topLeading) {
            ruler(layout)
            ForEach(Array(zip(voices.recorded, layout.recorded)), id: \.0.id) { meeting, frame in
                recorded(meeting, frame: frame)
            }
            ForEach(Array(zip(voices.upcoming, layout.upcoming)), id: \.0.id) { meeting, frame in
                upcoming(
                    meeting, frame: frame, isFirst: meeting.id == voices.upcoming.first?.id,
                    isNext: meeting.id == next)
            }
            if let nowX = layout.nowX {
                nowMark(x: nowX, width: layout.width)
            }
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
    }

    private func ruler(_ layout: DayAxisLayout) -> some View {
        Canvas { context, size in
            let line = context.resolve(GraphicsContext.Shading.color(PVDesign.line2))
            let split = min(max(0, layout.nowX ?? 0), size.width)
            var past = Path()
            past.move(to: CGPoint(x: 0, y: Self.baselineY))
            past.addLine(to: CGPoint(x: split, y: Self.baselineY))
            context.stroke(past, with: line, lineWidth: 1)
            var ahead = Path()
            ahead.move(to: CGPoint(x: split, y: Self.baselineY))
            ahead.addLine(to: CGPoint(x: size.width, y: Self.baselineY))
            context.stroke(ahead, with: line, style: StrokeStyle(lineWidth: 1, dash: [2, 5]))

            let hour = Date.FormatStyle.dateTime.hour().locale(locale)
            for tick in layout.ticks {
                var mark = Path()
                mark.move(to: CGPoint(x: tick.x, y: 74))
                mark.addLine(to: CGPoint(x: tick.x, y: 79))
                context.stroke(mark, with: line, lineWidth: 1)
                guard tick.labeled else { continue }
                context.draw(
                    Text(verbatim: tick.date.formatted(hour)).font(.caption).foregroundStyle(PVDesign.ink3),
                    at: CGPoint(x: tick.x, y: size.height), anchor: .bottom)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func recorded(_ meeting: TodayVoices.RecordedMeeting, frame: DayAxisLayout.Frame) -> some View {
        let duration = TalkDuration.text(meeting.duration)
        let cast = meeting.strip.cast
        return item(
            frame: frame, title: meeting.title, detail: duration,
            action: { onOpenMeeting(meeting.id) },
            mark: {
                Rectangle()
                    .fill(PVDesign.paper)
                    .frame(width: frame.width + 6, height: Self.stripHeight + 6)
                    .offset(x: -3, y: Self.stripY - 3)
                VoiceStrip(meeting.strip, size: .axis)
                    .frame(width: frame.width)
                    .offset(y: Self.stripY)
                dots(cast.voices.map(\.tint) + (cast.others.isEmpty ? [] : [.grey]))
                    .offset(y: Self.dotsY)
            }
        )
        .accessibilityLabel(Text(verbatim: "\(meeting.title), \(duration)"))
        .accessibilityValue(VoiceStrip(meeting.strip).spokenCast)
        .accessibilityIdentifier("home-day-meeting-\(meeting.id.rawValue.uuidString)")
    }

    private func upcoming(
        _ meeting: TodayVoices.UpcomingMeeting, frame: DayAxisLayout.Frame, isFirst: Bool, isNext: Bool
    ) -> some View {
        let event = meeting.event
        // Rounded up, so the count reaches zero only at the start.
        let wait = (event.startDate.timeIntervalSince(now) / 60).rounded(.up) * 60
        let caption = isNext
            ? L10n.format("in %@", TalkDuration.text(wait))
            : event.startDate.formatted(.dateTime.hour().minute().locale(locale))
        return item(
            frame: frame, title: event.title, detail: nil, action: { onOpenEvent(event) },
            mark: {
                Capsule()
                    .fill(PVDesign.paper)
                    .overlay {
                        if isFirst {
                            Capsule().strokeBorder(PVDesign.ink, lineWidth: 1.5)
                        } else {
                            Capsule()
                                .strokeBorder(PVDesign.ink, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .opacity(0.6)
                        }
                    }
                    .frame(width: frame.width, height: Self.stripHeight)
                    .offset(y: Self.stripY)
                HStack(spacing: 4) {
                    dots(meeting.cast.voices.map(\.tint))
                    Text(verbatim: caption)
                        .font(.subheadline.weight(isNext ? .semibold : .medium))
                        .foregroundStyle(isNext ? PVDesign.ink : PVDesign.ink3)
                        .fixedSize()
                }
                .frame(height: Self.dot)
                .offset(y: Self.dotsY)
            }
        )
        .accessibilityLabel(Text(verbatim: "\(event.title), \(caption)"))
        .accessibilityIdentifier("home-day-upcoming-\(event.id)")
    }

    /// A meeting placed at its start: the title over its mark and dots, all one button.
    private func item<Mark: View>(
        frame: DayAxisLayout.Frame, title: String, detail: String?, action: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                self.title(title, detail: detail, width: frame.titleWidth)
                mark()
            }
            .frame(width: max(frame.width, frame.titleWidth), height: Self.itemHeight, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(x: frame.x)
        .help(title)
    }

    /// The title and its minutes as one line, so they truncate together.
    @ViewBuilder
    private func title(_ title: String, detail: String?, width: CGFloat) -> some View {
        if width >= 12 {
            Text(Self.titleLine(title, detail: detail))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .offset(y: Self.titleY)
        }
    }

    private static func titleLine(_ title: String, detail: String?) -> AttributedString {
        var line = AttributedString(title)
        line.font = .callout.weight(.semibold)
        line.foregroundColor = PVDesign.ink
        guard let detail else { return line }
        var minutes = AttributedString("  \(detail)")
        minutes.font = .callout.weight(.medium)
        minutes.foregroundColor = PVDesign.ink3
        return line + minutes
    }

    /// "3:15": the locale's hour and minute without AM/PM; omitting the period
    /// through the format style pads a 12-hour clock to "03:15".
    static func clock(_ date: Date, locale: Locale, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        style.timeZone = timeZone
        var text = date.formatted(style.attributedStyle)
        let periods = text.runs.filter { $0.foundation.dateField == .amPM }.map(\.range)
        for range in periods.reversed() { text.removeSubrange(range) }
        return String(text.characters).trimmingCharacters(in: .whitespaces)
    }

    private func dots(_ tints: [VoiceCast.Tint]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                VoiceDot(tint: tint, size: Self.dot)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func nowMark(x: CGFloat, width: CGFloat) -> some View {
        let time = Self.clock(now, locale: locale)
        Rectangle()
            .fill(PVDesign.now)
            .frame(width: 1.6, height: 56)
            .offset(x: x - 0.8, y: 22)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        StatusPill(kind: .now, text: L10n.format("Now %@", time))
            .fixedSize()
            // Centred on now, kept inside the axis.
            .alignmentGuide(.leading) { pill in
                -min(max(0, x - pill.width / 2), max(0, width - pill.width))
            }
            .alignmentGuide(.top) { _ in -2 }
            .allowsHitTesting(false)
            .zIndex(1)
            .accessibilityIdentifier("home-day-now")
    }
}
