import ApplicationKit
import SwiftUI

/// Who is talking in the recording: the current speaker on top, then the
/// most recent voices with when they last spoke and their share of talk, and
/// "Others · n" past the six in colour. Rows rebuild when the live voices
/// refresh (at most once a second) and on one shared one-second tick for
/// their recency; every column has a fixed width, so neither moves the table.
struct RecordingLiveVoicesTable: View {
    let model: RecordingLiveVoicesModel
    let startedAt: Date

    @State private var showsOthers = false
    @State private var isNarrow = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let table = LiveVoiceTable(stage: model.stage, cast: model.cast)
        if !table.isEmpty {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let now = context.date.timeIntervalSince(startedAt)
                VStack(alignment: .leading, spacing: 0) {
                    PVCardCaption(text: L10n.text("Voices"), tint: PVDesign.ink)
                        .padding(.bottom, 8)
                    ForEach(table.rows) { row($0, in: table, now: now) }
                    if !table.others.isEmpty {
                        othersRow(table)
                        if showsOthers {
                            othersList(table, now: now)
                        }
                    }
                }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width < LiveVoicesTableMetrics.narrowWidth } action: {
                isNarrow = $0
            }
            // Bars past this width stop helping anyone compare shares.
            .frame(maxWidth: LiveVoicesTableMetrics.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-voices")
        }
    }

    private var metrics: LiveVoicesTableMetrics { LiveVoicesTableMetrics(isNarrow: isNarrow) }

    private func row(_ row: LiveVoiceTable.Row, in table: LiveVoiceTable, now: TimeInterval) -> some View {
        let name = LiveVoiceName.of(row.voice)
        let recency = LiveVoiceRecencyFormat.text(row: row, now: now)
        return HStack(spacing: 12) {
            nameColumn(name, size: row.isSpeaking ? 17 : 13.5, ink: row.voice.isMe ? PVDesign.ink : PVDesign.ink2) {
                if row.isSpeaking {
                    SpeakingBars(tint: row.voice.tint)
                } else {
                    VoiceDot(tint: row.voice.tint, size: 10, isOpen: !row.voice.isMe && row.voice.name == nil)
                }
            }
            Text(recency)
                .font(.system(size: 12, weight: row.isSpeaking ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(row.isSpeaking ? PVDesign.ink : PVDesign.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: metrics.recency, alignment: .leading)
            shareColumns(table.barFraction(row.voice.share), share: row.voice.share, tint: row.voice.tint)
        }
        .modifier(LiveVoiceRowShape(isSpeaking: row.isSpeaking))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, recency, row.voice.share.formatted(VoiceStrip.percent)].joined(separator: ", "))
        .accessibilityAddTraits(row.isSpeaking ? .isSelected : [])
        .accessibilityIdentifier("recording-voice-\(row.voice.key)")
    }

    private func othersRow(_ table: LiveVoiceTable) -> some View {
        let title = L10n.format("Others · %d", table.others.count)
        return Button {
            showsOthers.toggle()
        } label: {
            HStack(spacing: 12) {
                nameColumn(title, size: 13.5, ink: PVDesign.ink2) { VoiceDot(tint: .grey, size: 10) }
                Text(VoicesTableFormat.summary(table.others.map { LiveVoiceName.of($0.voice) }))
                    .font(.system(size: 12))
                    .foregroundStyle(PVDesign.ink3)
                    .lineLimit(1)
                    .frame(width: metrics.recency, alignment: .leading)
                shareColumns(table.barFraction(table.othersShare), share: table.othersShare, tint: .grey)
                Image(systemName: showsOthers ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PVDesign.ink3)
                    .accessibilityHidden(true)
            }
            .modifier(LiveVoiceRowShape(isSpeaking: false))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(showsOthers ? L10n.text("Expanded") : L10n.text("Collapsed"))
        .accessibilityIdentifier("recording-voices-others")
    }

    /// A large call can fold dozens of voices; past a few rows they scroll
    /// instead of pushing the captions off the stage.
    private func othersList(_ table: LiveVoiceTable, now: TimeInterval) -> some View {
        let visible = min(table.others.count, LiveVoicesTableMetrics.visibleOthers)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(table.others) { row($0, in: table, now: now) }
            }
        }
        .scrollDisabled(table.others.count <= LiveVoicesTableMetrics.visibleOthers)
        .frame(height: CGFloat(visible) * LiveVoicesTableMetrics.rowHeight)
    }

    /// A 14 pt glyph slot and the bold name, at the table's name width.
    private func nameColumn(
        _ name: String, size: CGFloat, ink: Color, @ViewBuilder glyph: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            glyph().frame(width: 14)
            Text(name)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
        }
        .frame(width: metrics.name, alignment: .leading)
    }

    private func shareColumns(_ fraction: Double, share: Double, tint: VoiceCast.Tint) -> some View {
        HStack(spacing: 12) {
            LevelTrackBar(fraction: fraction, fill: VoicePalette.color(tint, colorScheme: colorScheme))
                .frame(minWidth: 40, maxWidth: .infinity)
            Text(share.formatted(VoiceStrip.percent))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(PVDesign.ink)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

struct LiveVoicesTableMetrics {
    static let narrowWidth: CGFloat = 520
    static let maximumWidth: CGFloat = 760
    static let rowHeight: CGFloat = 30
    static let visibleOthers = 6
    let isNarrow: Bool

    var name: CGFloat { isNarrow ? 104 : 138 }
    var recency: CGFloat { isNarrow ? 124 : 150 }
}

/// A live voice is you or its diarization label (S3); remote speech the
/// diarizer has not reached yet reads "Others", in the table and the pills.
enum LiveVoiceName {
    static func of(_ voice: VoiceCast.Voice) -> String {
        VoiceName.of(isMe: voice.isMe, name: voice.name, label: of(key: voice.key))
    }

    static func of(key: String) -> String {
        switch key {
        case LiveVoiceStage.youKey: L10n.text("You")
        case LiveVoiceStage.unlabelledKey: L10n.text("Others")
        default: key
        }
    }
}

/// "speaking now · 0:20" for the current speaker, else "12 s ago".
enum LiveVoiceRecencyFormat {
    static func text(row: LiveVoiceTable.Row, now: TimeInterval) -> String {
        if row.isSpeaking {
            guard let speaking = row.speakingFor(at: now) else { return L10n.text("speaking now") }
            return L10n.format("speaking now · %@", ClockFormat.mmss(speaking, paddedMinutes: false))
        }
        return ago(max(0, now - row.lastHeard))
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        if whole < 60 { return L10n.format("%d s ago", max(1, whole)) }
        if whole < 3_600 { return L10n.format("%d min ago", whole / 60) }
        return L10n.format("%d h ago", whole / 3_600)
    }
}

/// The current speaker sits on a raised card; the rest are hairline rows.
private struct LiveVoiceRowShape: ViewModifier {
    let isSpeaking: Bool

    func body(content: Content) -> some View {
        if isSpeaking {
            content
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(PVDesign.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(PVDesign.line2, lineWidth: 1)
                }
                .padding(.horizontal, -10)
                .padding(.bottom, 4)
        } else {
            content
                .frame(height: LiveVoicesTableMetrics.rowHeight)
                .overlay(alignment: .top) { Rectangle().fill(PVDesign.line).frame(height: 1) }
        }
    }
}

/// A 6 pt capsule track filled to a fraction from the leading edge.
struct LevelTrackBar: View {
    let fraction: Double
    let fill: Color
    var track: Color = PVDesign.line

    var body: some View {
        Capsule()
            .fill(track)
            .frame(height: 6)
            .overlay { LevelBarFill(fraction: CGFloat(fraction)).fill(fill) }
            .accessibilityHidden(true)
    }
}

/// Three level bars in the voice's colour: this voice is speaking now.
private struct SpeakingBars: View {
    let tint: VoiceCast.Tint
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let scale = size.height / 12
            var path = Path()
            for (x, top, bottom) in [(2.0, 5.0, 7.0), (7.0, 2.0, 10.0), (12.0, 4.0, 8.0)] {
                path.move(to: CGPoint(x: x * scale, y: top * scale))
                path.addLine(to: CGPoint(x: x * scale, y: bottom * scale))
            }
            context.stroke(
                path, with: .color(VoicePalette.color(tint, colorScheme: colorScheme)),
                style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round))
        }
        .frame(width: 14, height: 12)
        .accessibilityHidden(true)
    }
}
