import AppKit
import ApplicationKit
import SwiftUI

/// The recording as one strip: who spoke when up to a red now edge, a time
/// ruler under it, and your notes and the questions asked of you above it.
struct RecordingLiveStrip: View {
    let model: RecordingLiveVoicesModel
    let startedAt: Date
    @State private var width: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    static let height = RecordingStageLayout.stripHeight
    private static let labelY: CGFloat = 7
    private static let glyph: CGFloat = 11
    private static let glyphSpacing: CGFloat = 5
    private static let stripTop: CGFloat = 26
    /// The fonts the labels draw in, for measuring them.
    private static let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let nowFont = NSFont.systemFont(ofSize: 11, weight: .bold)

    private struct Entry: Identifiable {
        let tick: LiveVoiceTick
        let text: String
        let width: CGFloat
        var id: UUID { tick.id }
    }

    var body: some View {
        let stage = model.stage
        let strip = stage.strip(cast: model.cast)
        // Measured when the stage changes, not on every clock second.
        let entries = stage.ticks.map { tick in
            let text = RecordingLiveStripLabel.text(tick)
            return Entry(
                tick: tick, text: text,
                width: Self.glyph + Self.glyphSpacing + PVTextMetrics.width(text, Self.tickFont))
        }
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            block(strip: strip, entries: entries, elapsed: max(0, context.date.timeIntervalSince(startedAt)))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-strip")
    }

    private func block(strip: VoiceStripColumns, entries: [Entry], elapsed: TimeInterval) -> some View {
        let scale = RecordingLiveStripLayout.scale(elapsed: elapsed, width: width)
        let nowX = scale.x(elapsed, width: width)
        let ticks = entries.map { (entry: $0, x: scale.x($0.tick.time, width: width)) }
        let nowText = L10n.text("now")
        let placement = RecordingLiveStripLayout.place(
            nowX: nowX, nowLabelWidth: PVTextMetrics.width(nowText, Self.nowFont),
            ticks: ticks.map { .init(id: $0.entry.id, x: $0.x, labelWidth: $0.entry.width) },
            width: width)
        return ZStack(alignment: .topLeading) {
            VoiceStrip(strip, size: .live, span: strip.duration / scale.horizon)
                .padding(.top, Self.stripTop)
            Canvas { canvas, size in
                drawTicks(ticks.map { ($0.entry.tick.kind, $0.x) }, in: &canvas)
                drawRuler(scale, in: &canvas, width: size.width)
                drawNow(x: nowX, in: &canvas, width: size.width)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if width > 0 {
                ForEach(entries) { entry in
                    if let leading = placement.ticks[entry.id] {
                        tickLabel(entry).position(x: leading + entry.width / 2, y: Self.labelY)
                    }
                }
                Text(nowText)
                    .font(Font(Self.nowFont))
                    .foregroundStyle(PVDesign.now)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: (placement.now.lowerBound + placement.now.upperBound) / 2, y: Self.labelY)
                    .accessibilityIdentifier("recording-strip-now")
            }
        }
    }

    private func tickLabel(_ entry: Entry) -> some View {
        let isNote = entry.tick.kind == .note
        return HStack(spacing: Self.glyphSpacing) {
            Image(systemName: isNote ? "pencil" : "bubble.left")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Self.glyph, height: Self.glyph)
            Text(entry.text)
                .font(Font(Self.tickFont))
                .lineLimit(1)
        }
        .foregroundStyle(isNote ? PVDesign.youInk : PVDesign.green)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.text)
        .accessibilityIdentifier("recording-strip-tick-\(entry.id.uuidString)")
    }

    private func drawTicks(_ ticks: [(kind: LiveVoiceTick.Kind, x: CGFloat)], in canvas: inout GraphicsContext) {
        let note = canvas.resolve(.color(VoicePalette.color(.you, colorScheme: colorScheme)))
        let question = canvas.resolve(.color(PVDesign.green))
        for tick in ticks {
            canvas.stroke(
                Self.line(x: tick.x, from: 18.9, to: 44.1), with: tick.kind == .note ? note : question,
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }

    private func drawRuler(_ scale: RecordingLiveStripLayout.Scale, in canvas: inout GraphicsContext, width: CGFloat) {
        var marks = canvas
        marks.opacity = 0.7
        let ink = canvas.resolve(.color(PVDesign.ink3))
        var majors: [(text: GraphicsContext.ResolvedText, x: CGFloat, size: CGSize)] = []
        for mark in scale.marks {
            // Half a point in, so the first and last marks keep their full width.
            let x = min(max(scale.x(mark.time, width: width), 0.5), max(0.5, width - 0.5))
            marks.stroke(Self.line(x: x, from: 47, to: mark.isMajor ? 53 : 50), with: ink, lineWidth: 1)
            guard mark.isMajor else { continue }
            let text = canvas.resolve(
                Text(ClockFormat.mmss(mark.time))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PVDesign.ink3))
            majors.append((text, x, text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))))
        }
        let centres = RecordingLiveStripLayout.rulerLabelCentres(
            majors.map { (x: $0.x, width: $0.size.width) }, width: width)
        for (major, centre) in zip(majors, centres) {
            guard let centre else { continue }
            let top = 67 - major.text.firstBaseline(in: major.size)
            canvas.draw(major.text, at: CGPoint(x: centre, y: top), anchor: .top)
        }
    }

    private func drawNow(x: CGFloat, in canvas: inout GraphicsContext, width: CGFloat) {
        let stroke: CGFloat = 2.4
        // Kept whole at either end of the strip.
        let x = min(max(x, stroke / 2), max(stroke / 2, width - stroke / 2))
        canvas.stroke(
            Self.line(x: x, from: 18 + stroke / 2, to: 50 - stroke / 2), with: .color(PVDesign.now),
            style: StrokeStyle(lineWidth: stroke, lineCap: .round))
    }

    private static func line(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Path {
        Path {
            $0.move(to: CGPoint(x: x, y: top))
            $0.addLine(to: CGPoint(x: x, y: bottom))
        }
    }
}

/// "your note · 04:40", "S2 asked you · 11:20"; a question nobody is
/// labelled for yet reads "Asked you · 11:20".
enum RecordingLiveStripLabel {
    static func text(_ tick: LiveVoiceTick) -> String {
        let time = ClockFormat.mmss(tick.time)
        switch tick.kind {
        case .note:
            return L10n.format("your note · %@", time)
        case .askedYou(let key):
            guard let asker = LiveVoiceName.asker(key) else { return L10n.format("Asked you · %@", time) }
            return L10n.format("%@ asked you · %@", asker, time)
        }
    }
}

/// Where the live strip's ruler marks and labels go. Pure.
enum RecordingLiveStripLayout {
    /// Seconds between major marks, tried in order; longer meetings double the last.
    static let majorSteps: [TimeInterval] = [300, 600, 900, 1_800, 3_600]
    static let minimumMajorSpacing: CGFloat = 70
    static let labelGap: CGFloat = 4
    static let tickLabelOffset: CGFloat = 6
    static let nowLabelOffset: CGFloat = 8
    static let minorsPerMajor = 5

    struct Mark: Equatable {
        let time: TimeInterval
        let isMajor: Bool
    }

    struct Scale: Equatable {
        /// The time at the strip's right edge.
        let horizon: TimeInterval
        let major: TimeInterval

        var minor: TimeInterval { major / Double(RecordingLiveStripLayout.minorsPerMajor) }

        var marks: [Mark] {
            (0...Int((horizon / minor).rounded())).map {
                Mark(time: Double($0) * minor, isMajor: $0.isMultiple(of: RecordingLiveStripLayout.minorsPerMajor))
            }
        }

        func x(_ time: TimeInterval, width: CGFloat) -> CGFloat {
            guard time.isFinite, width.isFinite else { return 0 }
            return CGFloat(min(max(0, time), horizon) / horizon) * max(0, width)
        }
    }

    struct Tick: Equatable {
        let id: UUID
        let x: CGFloat
        let labelWidth: CGFloat
    }

    struct Placement: Equatable {
        let now: ClosedRange<CGFloat>
        /// Leading edge per shown tick label; a tick without one keeps only its line.
        let ticks: [UUID: CGFloat]
    }

    /// Elapsed rounded up to the next major mark, with the smallest step that
    /// keeps majors `minimumMajorSpacing` apart.
    static func scale(elapsed: TimeInterval, width: CGFloat) -> Scale {
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        var index = 0
        var step = majorSteps[0]
        while true {
            let horizon = max(1, (elapsed / step).rounded(.up)) * step
            if horizon == step || width * CGFloat(step / horizon) >= minimumMajorSpacing {
                return Scale(horizon: horizon, major: step)
            }
            index += 1
            step = index < majorSteps.count ? majorSteps[index] : step * 2
        }
    }

    /// Centres for the major labels, in order: each centred on its mark, kept
    /// inside the strip, and nil when it would run into the one before it.
    static func rulerLabelCentres(_ labels: [(x: CGFloat, width: CGFloat)], width: CGFloat) -> [CGFloat?] {
        var reach = -CGFloat.infinity
        return labels.map { label in
            let half = label.width / 2
            let centre = min(max(label.x, half), max(half, width - half))
            guard centre - half >= reach + labelGap, centre + half <= width else { return nil }
            reach = centre + half
            return centre
        }
    }

    /// "now" goes first and always shows; then the newest tick first, right of
    /// its line or else left of it, hidden when neither side is free.
    static func place(nowX: CGFloat, nowLabelWidth: CGFloat, ticks: [Tick], width: CGFloat) -> Placement {
        var nowLeading = nowX + nowLabelOffset
        if nowLeading + nowLabelWidth > width { nowLeading = max(0, nowX - nowLabelOffset - nowLabelWidth) }
        let now = nowLeading...(nowLeading + nowLabelWidth)
        var taken = [now]
        var placed: [UUID: CGFloat] = [:]
        for tick in ticks.reversed() {
            let sides = [tick.x + tickLabelOffset, tick.x - tickLabelOffset - tick.labelWidth]
            let free = sides.first { leading in
                let trailing = leading + tick.labelWidth
                return leading >= 0 && trailing <= width
                    && taken.allSatisfy { leading >= $0.upperBound + labelGap || trailing <= $0.lowerBound - labelGap }
            }
            guard let free else { continue }
            placed[tick.id] = free
            taken.append(free...(free + tick.labelWidth))
        }
        return Placement(now: now, ticks: placed)
    }
}
