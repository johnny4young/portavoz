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
/// the now line, each meeting's mark and its title.
struct DayAxisLayout: Sendable, Equatable {
    /// Widths of a meeting's title line, measured in the axis's fonts.
    struct Title: Sendable, Equatable {
        /// The title and its minutes.
        let full: CGFloat
        /// The first word and an ellipsis: the narrowest title worth drawing.
        let word: CGFloat
        /// The minutes alone; zero when the line has none.
        let minutes: CGFloat

        static let none = Title(full: 0, word: 0, minutes: 0)

        init(full: CGFloat, word: CGFloat, minutes: CGFloat) {
            self.full = full
            self.word = min(word, full)
            self.minutes = minutes
        }
    }

    struct Item: Sendable, Equatable {
        let start: Date
        let end: Date
        let title: Title
        /// The voice dots and caption under the strip, which can outgrow a short meeting.
        let markWidth: CGFloat

        init(start: Date, end: Date, title: Title = .none, markWidth: CGFloat = 0) {
            self.start = start
            self.end = max(start, end)
            self.title = title
            self.markWidth = markWidth
        }

        init(start: Date, duration: TimeInterval, title: Title = .none, markWidth: CGFloat = 0) {
            self.init(start: start, end: start.addingTimeInterval(duration), title: title, markWidth: markWidth)
        }
    }

    struct Tick: Sendable, Equatable {
        let date: Date
        let x: CGFloat
        let labeled: Bool
    }

    enum Fit: Sendable, Equatable {
        case full, truncated, minutes, hidden
    }

    typealias TitleSlot = (x: CGFloat, width: CGFloat, fit: Fit)

    struct Frame: Sendable, Equatable {
        let x: CGFloat
        let width: CGFloat
        /// The strip or pill with the dots and caption under it.
        let markWidth: CGFloat
        let titleX: CGFloat
        let titleWidth: CGFloat
        let fit: Fit
    }

    static let pad: TimeInterval = 30 * 60
    static let minimumSpan: TimeInterval = 5 * 3_600
    static let titleGap: CGFloat = 10
    static let markGap: CGFloat = 6
    /// The now pill's width when none is measured; it sits on the title row.
    static let nowPillWidth: CGFloat = 80
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
        nowPillWidth: CGFloat = Self.nowPillWidth, calendar: Calendar
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
            max(0, CGFloat(date.timeIntervalSince(start)) * scale)
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
        let total = self.width

        let widths = recorded.map { max(Self.minimumRecordedWidth, position($0.end) - position($0.start)) }
        let extents = recorded.indices.map { max(widths[$0], recorded[$0].markWidth) }
        let marks = Self.spread(
            recorded.map { position($0.start) }, widths: widths, extents: extents, limit: nowX ?? total)
        let ahead = upcoming.map { position($0.start) }
        let aheadWidths = upcoming.map { max(Self.minimumUpcomingWidth, position($0.end) - position($0.start)) }
        let aheadExtents = upcoming.indices.map { max(aheadWidths[$0], upcoming[$0].markWidth) }
        // Centred on now, kept inside the axis, as the view draws it.
        let pill = nowX.map { x in
            let left = min(max(0, x - nowPillWidth / 2), max(0, total - nowPillWidth))
            return left...min(total, left + nowPillWidth)
        }
        let anchors = marks + ahead
        let titles = Self.titleRow(
            items, anchors: anchors, markEnds: zip(anchors, extents + aheadExtents).map(+), now: now, pill: pill,
            width: total)

        func frame(_ index: Int, x: CGFloat, width: CGFloat, markWidth: CGFloat) -> Frame {
            let title = titles[index]
            return Frame(
                x: x, width: width, markWidth: markWidth, titleX: title.x, titleWidth: title.width, fit: title.fit)
        }
        self.recorded = recorded.indices.map { frame($0, x: marks[$0], width: widths[$0], markWidth: extents[$0]) }
        self.upcoming = upcoming.indices.map {
            frame(recorded.count + $0, x: ahead[$0], width: aheadWidths[$0], markWidth: aheadExtents[$0])
        }
    }

    func x(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(axisStart) / axisEnd.timeIntervalSince(axisStart)) * width
    }

    /// Recorded marks keep a gap so neighbouring strips and dot groups never read as one;
    /// crowded ones give way to the left first, so only a strip that runs past `limit` crosses it.
    private static func spread(
        _ natural: [CGFloat], widths: [CGFloat], extents: [CGFloat], limit: CGFloat
    ) -> [CGFloat] {
        let rightmost = zip(natural, widths).map(+).max() ?? 0
        let byStart = natural.indices.sorted { natural[$0] < natural[$1] }
        var lefts = byStart.map { natural[$0] }
        var ceiling = max(limit, rightmost)
        for slot in lefts.indices.reversed() {
            lefts[slot] = min(lefts[slot], ceiling - extents[byStart[slot]])
            ceiling = lefts[slot] - markGap
        }
        var marks = natural
        var floor: CGFloat = 0
        for (slot, index) in byStart.enumerated() {
            marks[index] = max(lefts[slot], floor)
            floor = marks[index] + extents[index] + markGap
        }
        return marks
    }

    /// Titles share one row with the now pill: those that start before now end
    /// before it, the rest start after it. A title never reaches back over the
    /// previous meeting's mark.
    private static func titleRow(
        _ items: [Item], anchors: [CGFloat], markEnds: [CGFloat], now: Date, pill: ClosedRange<CGFloat>?,
        width: CGFloat
    ) -> [TitleSlot] {
        let byAnchor = items.indices.sorted { anchors[$0] < anchors[$1] }
        var lows = Array(repeating: CGFloat(0), count: items.count)
        var reach = -CGFloat.infinity
        for (previous, index) in zip(byAnchor, byAnchor.dropFirst()) {
            // An earlier, longer mark can still run past the one just before.
            reach = max(reach, markEnds[previous])
            lows[index] = min(anchors[index], reach + titleGap)
        }
        let groups: [(members: [Int], bounds: ClosedRange<CGFloat>)]
        if let pill {
            groups = [
                (byAnchor.filter { items[$0].start < now }, 0...max(0, pill.lowerBound - titleGap)),
                (byAnchor.filter { items[$0].start >= now }, min(width, pill.upperBound + titleGap)...width)
            ]
        } else {
            groups = [(byAnchor, 0...width)]
        }
        var titles = Array(repeating: TitleSlot(0, 0, .hidden), count: items.count)
        for (members, bounds) in groups {
            let placed = place(
                members.map { items[$0].title }, anchors: members.map { anchors[$0] },
                lows: members.map { max(bounds.lowerBound, lows[$0]) }, upper: bounds.upperBound)
            for (index, title) in zip(members, placed) {
                titles[index] = title
            }
        }
        return titles
    }

    private static func hour(_ date: Date, roundingUp: Bool, calendar: Calendar) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: date) else { return date }
        return roundingUp && hour.start < date ? hour.end : hour.start
    }

    /// Places titles, in order, on a row ending at `upper`. Each sits at its
    /// anchor when it can and otherwise ends before the next title, but never
    /// starts before its low. Titles that still collide are cut to one shared
    /// width, never below one word and an ellipsis, then fall back to their
    /// minutes, then go.
    static func place(
        _ titles: [Title], anchors: [CGFloat], lows: [CGFloat], upper: CGFloat
    ) -> [TitleSlot] {
        var row = TitleRow(titles: titles, anchors: anchors, lows: lows, upper: upper)
        for _ in 0..<(8 * titles.count + 8) {
            guard let worst = row.arrange() else { break }
            row.relieve(worst)
        }
        row.giveBack()
        return row.placed
    }
}

/// The working state of `DayAxisLayout.place`.
private struct TitleRow {
    typealias Fit = DayAxisLayout.Fit

    /// Room for float rounding when comparing positions.
    private static let slack: CGFloat = 0.001

    let titles: [DayAxisLayout.Title]
    let anchors: [CGFloat]
    let lows: [CGFloat]
    /// Where each title would rest with room to spare.
    let homes: [CGFloat]
    let upper: CGFloat
    var fits: [Fit]
    var widths: [CGFloat]
    var lefts: [CGFloat]

    init(titles: [DayAxisLayout.Title], anchors: [CGFloat], lows: [CGFloat], upper: CGFloat) {
        self.titles = titles
        self.anchors = anchors
        self.lows = lows
        homes = zip(anchors, lows).map { max($0, $1) }
        self.upper = upper
        fits = titles.map { $0.full > 0 ? .full : .hidden }
        widths = titles.map(\.full)
        lefts = homes
    }

    private var shown: [Int] { titles.indices.filter { fits[$0] != .hidden } }

    /// Sets each shown title as far right as it may go; returns the first that overruns its low.
    mutating func arrange() -> Int? {
        var ceiling = upper
        for index in shown.reversed() {
            lefts[index] = min(homes[index], ceiling - widths[index])
            ceiling = lefts[index] - DayAxisLayout.titleGap
        }
        return shown.first { lefts[$0] < lows[$0] - Self.slack }
    }

    /// Frees the room `worst` lacks from it and the titles packed against it.
    mutating func relieve(_ worst: Int) {
        var chain = [worst]
        for index in shown where index > worst {
            let last = chain[chain.count - 1]
            // A title resting at its anchor gains nothing from a cut.
            guard lefts[index] <= lefts[last] + widths[last] + DayAxisLayout.titleGap + Self.slack,
                  lefts[index] < homes[index] - Self.slack else { break }
            chain.append(index)
        }
        let cuttable = chain.filter { fits[$0] == .full && widths[$0] > titles[$0].word + Self.slack }
        if !cuttable.isEmpty {
            cut(cuttable, by: lows[worst] - lefts[worst])
        } else if let widest = chain.max(by: { widths[$0] < widths[$1] }) {
            let minutes = fits[widest] == .full && titles[widest].minutes > 0
            fits[widest] = minutes ? .minutes : .hidden
            widths[widest] = minutes ? titles[widest].minutes : 0
        }
    }

    /// One width for every title cut, as high as still frees `deficit`.
    private mutating func cut(_ cuttable: [Int], by deficit: CGFloat) {
        let current = widths
        func freed(_ level: CGFloat) -> CGFloat {
            cuttable.map { current[$0] - min(current[$0], max(titles[$0].word, level)) }.reduce(0, +)
        }
        var level: CGFloat = 0
        var high = cuttable.map { current[$0] }.max() ?? 0
        for _ in 0..<32 {
            let mid = (level + high) / 2
            if freed(mid) >= deficit { level = mid } else { high = mid }
        }
        for index in cuttable {
            widths[index] = min(current[index], max(titles[index].word, level))
        }
    }

    /// A shared cut can take more than one title needed: gives back what still fits.
    mutating func giveBack() {
        for index in titles.indices where fits[index] == .full && widths[index] < titles[index].full {
            let cut = widths[index]
            var fitting = cut
            var high = titles[index].full
            for _ in 0..<24 {
                widths[index] = (fitting + high) / 2
                if arrange() == nil { fitting = widths[index] } else { high = widths[index] }
            }
            widths[index] = max(cut, fitting.rounded(.down))
        }
        if arrange() != nil {
            for index in titles.indices where lefts[index] < lows[index] - Self.slack { fits[index] = .hidden }
        }
    }

    var placed: [DayAxisLayout.TitleSlot] {
        titles.indices.map { index in
            switch fits[index] {
            case .hidden: (anchors[index], 0, .hidden)
            case .full where widths[index] < titles[index].full: (lefts[index], widths[index], .truncated)
            default: (lefts[index], widths[index], fits[index])
            }
        }
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
    private static let dotSpacing: CGFloat = 3
    private static let captionSpacing: CGFloat = 4
    /// The fonts the axis draws its text in, for measuring it.
    private static let titleFont = PVTextMetrics.font(.callout, .semibold)
    private static let minutesFont = PVTextMetrics.font(.callout, .medium)
    private static let nextCaptionFont = PVTextMetrics.font(.subheadline, .semibold)
    private static let captionFont = PVTextMetrics.font(.subheadline, .medium)
    private static let nowFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
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
        let next = voices.upcoming.first { $0.event.startDate > now }?.id
        let layout = DayAxisLayout(
            day: voices.day,
            now: now,
            recorded: voices.recorded.map {
                .init(
                    start: $0.startedAt, duration: $0.duration,
                    title: Self.measure($0.title, detail: TalkDuration.text($0.duration)),
                    markWidth: Self.dotsWidth(Self.dotTints($0.strip.cast).count))
            },
            upcoming: voices.upcoming.map {
                .init(
                    start: $0.event.startDate, end: $0.event.endDate ?? $0.event.startDate + DayAxisLayout.pad,
                    title: Self.measure($0.event.title, detail: nil),
                    markWidth: upcomingMarkWidth($0, isNext: $0.id == next))
            },
            width: width,
            // The pill's 8 pt side padding.
            nowPillWidth: PVTextMetrics.width(nowText, Self.nowFont) + 16,
            calendar: .current)
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
                dots(Self.dotTints(meeting.strip.cast))
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
        let caption = caption(event, isNext: isNext)
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
                HStack(spacing: Self.captionSpacing) {
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

    /// The invitee dots and the caption beside them.
    private func upcomingMarkWidth(_ meeting: TodayVoices.UpcomingMeeting, isNext: Bool) -> CGFloat {
        let font = isNext ? Self.nextCaptionFont : Self.captionFont
        let caption = PVTextMetrics.width(caption(meeting.event, isNext: isNext), font)
        return Self.dotsWidth(meeting.cast.voices.count) + Self.captionSpacing + caption
    }

    private func caption(_ event: UpcomingEvent, isNext: Bool) -> String {
        guard isNext else { return event.startDate.formatted(.dateTime.hour().minute().locale(locale)) }
        // Rounded up, so the count reaches zero only at the start.
        let wait = (event.startDate.timeIntervalSince(now) / 60).rounded(.up) * 60
        return L10n.format("in %@", TalkDuration.text(wait))
    }

    /// A meeting at its start: the title on the title row, which can sit left of
    /// its mark, over the mark and dots; both are one button.
    private func item<Mark: View>(
        frame: DayAxisLayout.Frame, title: String, detail: String?, action: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark
    ) -> some View {
        let origin = min(frame.x, frame.titleX)
        let end = max(frame.x + frame.markWidth, frame.titleX + frame.titleWidth)
        let band = Self.stripY - 8
        return Button(action: action) {
            ZStack(alignment: .topLeading) {
                self.title(title, detail: detail, frame: frame)
                    .offset(x: frame.titleX - origin, y: Self.titleY)
                ZStack(alignment: .topLeading) { mark() }
                    .offset(x: frame.x - origin)
            }
            .frame(width: end - origin, height: Self.itemHeight, alignment: .topLeading)
            // The title row and the mark's band only: a neighbour's title may sit over this mark.
            .contentShape(Rects(rects: [
                CGRect(x: frame.titleX - origin, y: 0, width: frame.titleWidth, height: band),
                CGRect(x: frame.x - origin, y: band, width: frame.markWidth, height: Self.itemHeight - band)
            ]))
        }
        .buttonStyle(.plain)
        .offset(x: origin)
        .help(title)
    }

    /// The title and its minutes as one line, so they truncate together.
    @ViewBuilder
    private func title(_ title: String, detail: String?, frame: DayAxisLayout.Frame) -> some View {
        switch frame.fit {
        case .full:
            // Unclipped: a point of rounding against the measured width must not cost an ellipsis.
            Text(Self.titleLine(title, detail: detail)).fixedSize()
        case .truncated:
            Text(Self.titleLine(title, detail: detail))
                .lineLimit(1)
                .frame(width: frame.titleWidth, alignment: .leading)
        case .minutes:
            Text(Self.minutes(detail ?? "")).fixedSize()
        case .hidden:
            EmptyView()
        }
    }

    private static func titleLine(_ title: String, detail: String?) -> AttributedString {
        var line = AttributedString(title)
        line.font = .callout.weight(.semibold)
        line.foregroundColor = PVDesign.ink
        guard let detail else { return line }
        return line + minutes("  \(detail)")
    }

    private static func minutes(_ text: String) -> AttributedString {
        var minutes = AttributedString(text)
        minutes.font = .callout.weight(.medium)
        minutes.foregroundColor = PVDesign.ink3
        return minutes
    }

    /// The widths `titleLine` draws at.
    private static func measure(_ title: String, detail: String?) -> DayAxisLayout.Title {
        let full = PVTextMetrics.width(title, titleFont)
            + (detail.map { PVTextMetrics.width("  \($0)", minutesFont) } ?? 0)
        return DayAxisLayout.Title(
            full: full,
            word: title.split(separator: " ").first.map { PVTextMetrics.width("\($0)…", titleFont) } ?? full,
            minutes: detail.map { PVTextMetrics.width($0, minutesFont) } ?? 0)
    }

    private static func dotTints(_ cast: VoiceCast) -> [VoiceCast.Tint] {
        cast.voices.map(\.tint) + (cast.others.isEmpty ? [] : [.grey])
    }

    private static func dotsWidth(_ count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * dot + CGFloat(count - 1) * dotSpacing : 0
    }

    /// "3:15": the locale's hour and minute without AM/PM; omitting the period
    /// through the format style pads a 12-hour clock to "03:15".
    nonisolated static func clock(_ date: Date, locale: Locale, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        style.timeZone = timeZone
        var text = date.formatted(style.attributedStyle)
        let periods = text.runs.filter { $0.foundation.dateField == .amPM }.map(\.range)
        for range in periods.reversed() { text.removeSubrange(range) }
        return String(text.characters).trimmingCharacters(in: .whitespaces)
    }

    private func dots(_ tints: [VoiceCast.Tint]) -> some View {
        HStack(spacing: Self.dotSpacing) {
            ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                VoiceDot(tint: tint, size: Self.dot)
            }
        }
        .fixedSize()
    }

    private var nowText: String { L10n.format("Now %@", Self.clock(now, locale: locale)) }

    @ViewBuilder
    private func nowMark(x: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(PVDesign.now)
            .frame(width: 1.6, height: 56)
            .offset(x: x - 0.8, y: 22)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        StatusPill(text: nowText)
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

private struct Rects: Shape {
    let rects: [CGRect]

    func path(in _: CGRect) -> Path {
        Path { $0.addRects(rects) }
    }
}
