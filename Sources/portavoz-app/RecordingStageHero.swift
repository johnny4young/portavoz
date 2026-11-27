import SwiftUI

/// The recording's hero: the elapsed time in display type, the meeting with
/// when it started and how many voices so far, and Stop. The type steps down
/// with the width it is given, so the row never wraps or truncates Stop.
struct RecordingStageHero: View {
    let controller: RecordingController
    let onStop: () -> Void

    @State private var scale = RecordingStageHeroScale.wide

    var body: some View {
        HStack(alignment: .center, spacing: scale.spacing) {
            RecordingElapsedClock(startedAt: controller.startedAt, size: scale.clock)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.title ?? L10n.text("Recording"))
                    .pvDisplay(scale.title)
                    .foregroundStyle(PVDesign.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("recording-stage-title")
                RecordingStageDetail(controller: controller)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onStop) {
                Label("Stop", systemImage: PVSymbol.stop)
                    .padding(.horizontal, scale == .compact ? 2 : 6)
            }
            .buttonStyle(.pvStop)
            .controlSize(scale == .compact ? .large : .extraLarge)
            .keyboardShortcut(".")
            .fixedSize()
            .accessibilityIdentifier("recording-stop")
        }
        .padding(.horizontal, 20)
        .onGeometryChange(for: RecordingStageHeroScale.self) {
            RecordingStageHeroScale(width: $0.size.width)
        } action: { scale = $0 }
    }
}

enum RecordingStageHeroScale: Equatable {
    case wide, medium, compact

    init(width: CGFloat) {
        self = width >= 840 ? .wide : width >= 680 ? .medium : .compact
    }

    var clock: CGFloat {
        switch self {
        case .wide: 112
        case .medium: 88
        case .compact: 64
        }
    }

    var title: PVDisplayStyle {
        switch self {
        case .wide: .stageTitle
        case .medium: .stageTitle.sized(26)
        case .compact: .stageTitle.sized(22)
        }
    }

    var spacing: CGFloat { self == .compact ? 18 : 30 }
}

/// "Meet · started 5:30 PM · 12 voices so far". The only part of the hero
/// that reads live voices, so a new voice re-renders this line alone.
struct RecordingStageDetail: View {
    let controller: RecordingController

    var body: some View {
        Text(Self.line(
            apps: controller.tappedMeetingApps,
            startedAt: controller.startedAt,
            voices: controller.liveVoices.stage.voices.count))
            .font(.system(size: 13))
            .foregroundStyle(PVDesign.ink2)
            .lineLimit(2)
            .accessibilityIdentifier("recording-stage-detail")
    }

    static func line(apps: [String], startedAt: Date, voices: Int) -> String {
        let started = startedAt.formatted(
            .dateTime.hour().minute().locale(AppLanguage.current.locale))
        var parts = apps.isEmpty ? [] : [apps.joined(separator: ", ")]
        parts.append(L10n.format("started %@", started))
        if voices == 1 {
            parts.append(L10n.text("1 voice so far"))
        } else if voices > 1 {
            parts.append(L10n.format("%d voices so far", voices))
        }
        return parts.joined(separator: " · ")
    }
}

/// The elapsed time as minutes and dimmer seconds in equal digit cells. The
/// ticking timeline lives in an overlay of a hidden same-size placeholder, so
/// a tick repaints the numeral without re-measuring the hero.
private struct RecordingElapsedClock: View {
    let startedAt: Date
    let size: CGFloat

    @State private var placeholder = RecordingClockTemplate.placeholder(
        for: ClockFormat.mmss(0))

    var body: some View {
        numeral(placeholder)
            .hidden()
            .overlay(alignment: .leading) {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let clock = ClockFormat.mmss(context.date.timeIntervalSince(startedAt), truncating: true)
                    numeral(clock)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: clock))
                        .accessibilityIdentifier("recording-elapsed-time")
                        .onChange(
                            of: RecordingClockTemplate.placeholder(for: clock), initial: true
                        ) { _, widest in
                            placeholder = widest
                        }
                }
            }
    }

    private func numeral(_ clock: String) -> some View {
        let split = clock.lastIndex(of: ":") ?? clock.endIndex
        // The numeral's side bearing and line gap, trimmed in proportion to its size.
        let trim = size / PVDisplayStyle.countdown.size
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            DisplayTimeText(String(clock[..<split]), style: .countdown.sized(size))
                .foregroundStyle(PVDesign.ink)
            DisplayTimeText(String(clock[split...]), style: .countdownTrail.sized(size))
                .foregroundStyle(PVDesign.ink3)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, -8 * trim)
        .padding(.vertical, -26 * trim)
    }
}
