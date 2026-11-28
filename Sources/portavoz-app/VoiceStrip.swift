import ApplicationKit
import PortavozCore
import SwiftUI

/// The meeting's time axis as one flat strip: each column takes the colour of
/// whoever spoke then, and silence shows the track.
struct VoiceStrip: View {
    enum Size {
        case row
        /// A summary strip inside a card.
        case card
        case player
        case live
        /// A meeting on Today's day axis.
        case axis
        /// A pick-up row: where listening stopped, with the rest dimmed.
        case resume

        var height: CGFloat {
            switch self {
            case .row: 6
            case .card, .resume: 8
            case .player: 18
            case .live: 16
            case .axis: 10
            }
        }

        var radius: CGFloat {
            switch self {
            case .row: 3
            case .card, .resume: 4
            case .player, .live, .axis: 5
            }
        }

        /// Compact strips calm short runs and draw no playhead.
        var isCompact: Bool { self == .row || self == .card || self == .axis }

        /// Dark keeps 3:1 between every dimmed tint and the track.
        func unplayedOpacity(_ colorScheme: ColorScheme) -> Double {
            if colorScheme == .dark { return 0.7 }
            return self == .resume ? 0.3 : 0.45
        }
    }

    /// How far the playhead and chapter ticks reach past the strip.
    private static let overhang: CGFloat = 4
    static var percent: FloatingPointFormatStyle<Double>.Percent {
        .percent.precision(.fractionLength(0)).locale(AppLanguage.current.locale)
    }

    let strip: VoiceStripColumns
    let size: Size
    /// Draws one voice and leaves the rest as track.
    let only: UInt8?
    /// Played fraction, 0…1; nil draws everything as played.
    let progress: Double?
    /// Chapter starts as fractions, 0…1.
    let ticks: [Double]
    /// Fraction of the width the columns fill; the rest stays track.
    let span: Double
    /// A moment drawn as the playhead line, at any size.
    let mark: Double?
    @Environment(\.colorScheme) private var colorScheme

    init(
        _ strip: VoiceStripColumns, size: Size = .row, only: UInt8? = nil,
        progress: Double? = nil, ticks: [Double] = [], span: Double = 1, mark: Double? = nil
    ) {
        self.strip = strip
        self.size = size
        self.only = only
        self.mark = mark.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.progress = progress.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.ticks = ticks.filter { $0.isFinite && (0...1).contains($0) }
        self.span = span.isFinite ? min(1, max(0, span)) : 1
    }

    var body: some View {
        Canvas { context, canvas in
            drawRuns(in: &context, size: canvas)
        }
        .clipShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
        .frame(height: size.height)
        .overlay {
            if playhead != nil || !ticks.isEmpty {
                Canvas { context, canvas in
                    drawMarks(in: &context, size: canvas)
                }
                .padding(.vertical, -Self.overhang)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Who spoke when"))
        .accessibilityValue(spokenCast)
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(strip.columns.isEmpty)
    }

    /// A resume strip at zero is unheard: everything dims and no playhead marks a spot.
    private var playhead: Double? {
        if let mark { return mark }
        guard !size.isCompact, let progress, size != .resume || progress > 0 else { return nil }
        return progress
    }

    /// The cast in order, "You 25%, Marta 30%, Others · 2"; unnamed and
    /// folded voices are counted. Empty when the strip has nothing attributed.
    var spokenCast: String {
        guard !strip.columns.isEmpty else { return "" }
        let legend = Self.legend(strip.cast)
        var parts = legend.named.map { "\($0.name) \($0.voice.share.formatted(Self.percent))" }
        if legend.unnamed > 0 { parts.append(L10n.format("Others · %d", legend.unnamed)) }
        return parts.joined(separator: ", ")
    }

    /// Named voices in cast order; unnamed and folded voices only count.
    static func legend(_ cast: VoiceCast) -> (named: [(voice: VoiceCast.Voice, name: String)], unnamed: Int) {
        let named = cast.voices.compactMap { voice in
            (voice.isMe ? L10n.text("You") : voice.name).map { (voice: voice, name: $0) }
        }
        return (named, cast.others.count + cast.voices.count - named.count)
    }

    private func drawRuns(in context: inout GraphicsContext, size canvas: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(PVDesign.line))
        let reach = canvas.width * span
        let count = VoiceColumns.count(forWidth: reach)
        var columns = VoiceColumns.resampled(strip.columns, count: count)
        if size.isCompact { columns = VoiceColumns.calmed(columns) }
        guard !columns.isEmpty else { return }
        // Resolved once per draw: dynamic voice colours are costly per run.
        let shadings = strip.tints.map {
            context.resolve(
                GraphicsContext.Shading.color(VoicePalette.color($0, colorScheme: colorScheme)))
        }
        var ahead = context
        ahead.opacity = size.unplayedOpacity(colorScheme)
        let column = reach / CGFloat(columns.count)
        let split = ((progress ?? 1) * canvas.width).rounded()
        for run in VoiceColumns.runs(columns) where Int(run.voice) < shadings.count {
            guard only == nil || only == run.voice else { continue }
            // Whole points, so neighbouring runs meet without a seam.
            let left = (CGFloat(run.start) * column).rounded()
            let right = (CGFloat(run.end) * column).rounded()
            let shading = shadings[Int(run.voice)]
            if left < min(right, split) {
                context.fill(
                    Path(CGRect(x: left, y: 0, width: min(right, split) - left, height: canvas.height)),
                    with: shading)
            }
            if max(left, split) < right {
                ahead.fill(
                    Path(CGRect(
                        x: max(left, split), y: 0, width: right - max(left, split),
                        height: canvas.height)),
                    with: shading)
            }
        }
    }

    private func drawMarks(in context: inout GraphicsContext, size canvas: CGSize) {
        let ink = context.resolve(GraphicsContext.Shading.color(PVDesign.ink))
        var tickContext = context
        tickContext.opacity = 0.45
        for tick in ticks {
            var path = Path()
            path.move(to: CGPoint(x: tick * canvas.width, y: 0))
            path.addLine(to: CGPoint(x: tick * canvas.width, y: canvas.height - Self.overhang))
            tickContext.stroke(path, with: ink, lineWidth: 1)
        }
        guard let playhead else { return }
        let width: CGFloat = 2.2
        // Kept whole at either end; inset by the round cap so it ends exactly at the overhang.
        let x = min(max(playhead * canvas.width, width / 2), canvas.width - width / 2)
        var path = Path()
        path.move(to: CGPoint(x: x, y: width / 2))
        path.addLine(to: CGPoint(x: x, y: canvas.height - width / 2))
        context.stroke(path, with: ink, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

/// Each named voice of a strip with its share, then "Others · n". The strip
/// already reads the cast to VoiceOver, so the legend stays hidden from it.
struct VoiceLegend: View {
    let cast: VoiceCast
    var font: Font = .callout
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let legend = VoiceStrip.legend(cast)
        ForEach(legend.named, id: \.voice.id) { entry in
            HStack(spacing: 5) {
                Circle()
                    .fill(VoicePalette.color(entry.voice.tint, colorScheme: colorScheme))
                    .frame(width: 7, height: 7)
                Text(entry.name)
                    .font(font.weight(.semibold))
                    .foregroundStyle(PVDesign.ink)
                Text(entry.voice.share.formatted(VoiceStrip.percent))
                    .font(font.monospacedDigit())
                    .foregroundStyle(PVDesign.ink3)
            }
            .lineLimit(1)
            .accessibilityHidden(true)
        }
        if legend.unnamed > 0 {
            Text(L10n.format("Others · %d", legend.unnamed))
                .font(font.weight(.semibold))
                .foregroundStyle(PVDesign.ink2)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }
}

/// One voice's colour as a dot; an unnamed voice is an open ring.
struct VoiceDot: View {
    let tint: VoiceCast.Tint
    var size: CGFloat = 7
    var isOpen = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colour = VoicePalette.color(tint, colorScheme: colorScheme)
        Group {
            if isOpen {
                Circle().strokeBorder(colour, lineWidth: 1.6)
            } else {
                Circle().fill(colour)
            }
        }
        .frame(width: size, height: size)
    }
}

/// How a voice is named: "You", else its name, else its diarization label.
enum VoiceName {
    nonisolated static func of(isMe: Bool, name: String?, label: String) -> String {
        isMe ? L10n.text("You") : name ?? label
    }

    nonisolated static func of(_ speaker: Speaker) -> String {
        of(isMe: speaker.isMe, name: speaker.displayName, label: speaker.label)
    }

    /// VoiceOver value: whether the name belongs to this meeting or a remembered person.
    static func linkState(_ speaker: Speaker) -> String {
        speaker.personID == nil
            ? L10n.text("Meeting-only name")
            : L10n.text("Linked to a remembered person")
    }
}
