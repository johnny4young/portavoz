import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI
import UniformTypeIdentifiers

/// The docked player: the meeting's voice strip with chapter ticks and a
/// playhead, then one row of transport, readout and quiet toggles. Its own
/// View so the 5 fps playback ticks don't re-render the whole detail.
struct MeetingPlayerBar: View {
    let player: MeetingPlaybackSession
    let strip: MeetingPlayerStrip?
    let chapters: [MeetingTranscriptContent.Chapter]
    let exportClip: @MainActor @Sendable (
        ClosedRange<TimeInterval>, URL
    ) async -> String?

    @State private var exporting = false
    @State private var exportError: String?

    private static let rates: [Float] = [1, 1.25, 1.5, 2]

    /// What a narrower row gives up, in order: the readout's room, then the
    /// toggles' titles, then the clock's size and the speed's capsule.
    private enum Fit {
        case regular, tight, quiet, compact

        var readoutWidth: CGFloat { self == .regular ? 180 : 0 }
    }

    var body: some View {
        let chapters = PlayerChapters(chapters, timeline: player.timeline)
        VStack(alignment: .leading, spacing: 6) {
            PlayerStripScrubber(player: player, strip: strip, chapters: chapters)
            ViewThatFits(in: .horizontal) {
                controlRow(.regular, chapters: chapters)
                controlRow(.tight, chapters: chapters)
                controlRow(.quiet, chapters: chapters)
                controlRow(.compact, chapters: chapters)
            }
            if player.clipRange != nil { clipRow }
        }
        .alert(
            "Could not export",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func controlRow(_ fit: Fit, chapters: PlayerChapters) -> some View {
        HStack(spacing: fit == .compact ? 8 : 12) {
            playButton
            skipButton(seconds: -15, symbol: "gobackward.15", identifier: "player-skip-back")
            skipButton(seconds: 15, symbol: "goforward.15", identifier: "player-skip-forward")
            PlayerClock(player: player, size: fit == .compact ? 18 : 22)
            // The readout takes what the controls leave and never decides the fit.
            Color.clear
                .frame(minWidth: fit.readoutWidth, maxWidth: .infinity)
                .frame(height: 26)
                .overlay(alignment: .leading) {
                    PlayerReadout(player: player, strip: strip, chapters: chapters)
                }
            toggles(showsTitles: fit == .regular || fit == .tight)
            rateMenu(compact: fit == .compact)
            optionsMenu
        }
    }

    @ViewBuilder
    private func toggles(showsTitles: Bool) -> some View {
        PlayerToggleChip(
            title: "Skip silence", symbol: "chevron.forward.2", isOn: player.skipSilence,
            showsTitle: showsTitles, identifier: "player-skip-silence"
        ) {
            player.skipSilence.toggle()
        }
        if let me = strip?.myVoice {
            PlayerToggleChip(
                title: "Only my voice", symbol: "person", isOn: player.voiceFocus == me.speakerID,
                showsTitle: showsTitles, identifier: "player-only-my-voice"
            ) {
                player.toggleFocus(on: me.speakerID, turns: me.turns)
            }
        }
        if player.canClearPlayback {
            PlayerToggleChip(
                title: "Reduce echo", symbol: "mic", isOn: player.clearPlayback,
                showsTitle: showsTitles, identifier: "player-clear-playback"
            ) {
                player.clearPlayback.toggle()
            }
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if player.hasPlaybackFailed {
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(PVDesign.onInk, PVDesign.ink3)
                .font(.system(size: 34))
                .help("Can't play this audio")
                .accessibilityElement()
                .accessibilityLabel(L10n.text("Can't play this audio"))
                .accessibilityIdentifier("player-playback-failed")
        } else {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(PVDesign.onInk, PVDesign.ink)
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(L10n.text(player.isPlaying ? "Pause" : "Play"))
            .accessibilityIdentifier("player-play-pause")
        }
    }

    private func skipButton(seconds: TimeInterval, symbol: String, identifier: String) -> some View {
        Button {
            player.skip(by: seconds)
        } label: {
            Image(systemName: symbol)
                .font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PVDesign.ink2)
        .help(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
        .accessibilityLabel(L10n.text(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds"))
        .accessibilityIdentifier(identifier)
    }

    private func rateMenu(compact: Bool) -> some View {
        Menu {
            ForEach(Self.rates, id: \.self) { rate in
                Button {
                    player.rate = rate
                } label: {
                    if rate == player.rate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
                .accessibilityIdentifier("player-speed-\(Self.rateLabel(rate))")
            }
        } label: {
            if compact {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.50percent").imageScale(.small)
                    Text(Self.rateLabel(player.rate)).monospacedDigit()
                }
                .font(.callout.weight(.semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(PVDesign.ink2)
        .fixedSize()
        .padding(.horizontal, compact ? 0 : 10)
        .frame(height: 26)
        .overlay {
            if !compact { Capsule().strokeBorder(PVDesign.line2) }
        }
        .help("Playback speed")
        .accessibilityLabel(L10n.text("Playback speed"))
        .accessibilityValue(Self.rateLabel(player.rate))
        .accessibilityIdentifier("player-speed")
    }

    private var optionsMenu: some View {
        Menu {
            Button("Mark clip start") { player.markClipStart() }
                .accessibilityIdentifier("clip-mark-start")
            Button("Mark clip end") { player.markClipEnd() }
                .accessibilityIdentifier("clip-mark-end")
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(PVDesign.ink2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback options")
        .accessibilityLabel(L10n.text("Playback options"))
        .accessibilityIdentifier("player-options")
    }

    private static func rateLabel(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// A marked clip and its export.
    private var clipRow: some View {
        HStack(spacing: 8) {
            if let range = player.clipRange {
                Label(
                    L10n.format("Clip %@", ClockFormat.mmss(range.upperBound - range.lowerBound, paddedMinutes: false)),
                    systemImage: "scissors")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ink3)
                Button {
                    exportClip(range)
                } label: {
                    if exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .controlSize(.small)
                .disabled(exporting)
                .accessibilityIdentifier("clip-export")
                Button {
                    player.clearClip()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Discard the clip")
                .accessibilityLabel(L10n.text("Discard the clip"))
                .accessibilityIdentifier("clip-discard")
            }
            Spacer()
        }
        .font(.caption)
    }

    private func exportClip(_ range: ClosedRange<TimeInterval>) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clip.m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.prompt = L10n.text("Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            if let message = await exportClip(range, url) {
                exportError = message
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

}

/// The voice strip as a scrubber: chapter titles over their ticks, the
/// playhead, the marked clip and long silences drawn short with their length.
/// Reads the 5 fps playback time itself so a tick redraws only the strip.
private struct PlayerStripScrubber: View {
    let player: MeetingPlaybackSession
    let strip: MeetingPlayerStrip?
    let chapters: PlayerChapters

    var body: some View {
        let timeline = player.timeline
        VStack(alignment: .leading, spacing: 2) {
            if !chapters.isEmpty {
                PlayerChapterLabels(
                    chapters: chapters, current: chapters.index(at: player.currentTime),
                    onSeek: { player.seek(to: chapters.starts[$0]) })
            }
            VoiceStrip(
                strip?.strip ?? .empty, size: .player,
                only: player.voiceFocus.flatMap { strip?.voiceIndex(of: $0) },
                progress: timeline.fraction(at: player.currentTime), ticks: chapters.ticks)
                .overlay {
                    PlayerStripMarks(timeline: timeline, clip: player.clipRange).equatable()
                }
                .padding(.vertical, 4)
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                player.seek(to: timeline.time(at: value.location.x / max(1, geo.size.width)))
                            })
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Playback position"))
                .accessibilityValue(Text(ClockFormat.mmss(player.currentTime, paddedMinutes: false)))
                .accessibilityAdjustableAction { direction in
                    let step: TimeInterval = 10
                    switch direction {
                    case .increment: player.seek(to: min(timeline.duration, player.currentTime + step))
                    case .decrement: player.seek(to: max(0, player.currentTime - step))
                    @unknown default: return
                    }
                }
                .accessibilityIdentifier("player-strip")
        }
    }
}

/// The marked clip and long silences with their length; unchanged by the
/// playback clock, so a tick never redraws them.
private struct PlayerStripMarks: View, Equatable {
    let timeline: PlaybackTimeline
    let clip: ClosedRange<TimeInterval>?

    var body: some View {
        Canvas { context, size in
            if let clip { drawClip(clip, in: &context, size: size) }
            for gap in timeline.parts where gap.isGap {
                drawGap(gap.range, in: &context, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawClip(_ clip: ClosedRange<TimeInterval>, in context: inout GraphicsContext, size: CGSize) {
        let lower = timeline.fraction(at: clip.lowerBound) * size.width
        let upper = timeline.fraction(at: clip.upperBound) * size.width
        let rect = CGRect(x: lower, y: 0, width: max(2, upper - lower), height: size.height).insetBy(dx: 0.75, dy: 0.75)
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 4), with: .color(PVDesign.ink), lineWidth: 1.5)
    }

    private func drawGap(_ gap: ClosedRange<TimeInterval>, in context: inout GraphicsContext, size: CGSize) {
        let left = timeline.fraction(at: gap.lowerBound) * size.width
        let right = timeline.fraction(at: gap.upperBound) * size.width
        var edges = Path()
        for x in [left + 1, right - 1] {
            edges.move(to: CGPoint(x: x, y: 3))
            edges.addLine(to: CGPoint(x: x, y: size.height - 3))
        }
        context.stroke(edges, with: .color(PVDesign.ink3.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        let label = Text(Duration.seconds(gap.upperBound - gap.lowerBound)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.ink3)
        let resolved = context.resolve(label)
        // Measured unconstrained: a bounded measure wraps to fit and never says no.
        let measured = resolved.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
        guard measured.width > 0, measured.width <= right - left - 8 else { return }
        context.draw(resolved, at: CGPoint(x: (left + right) / 2, y: size.height / 2))
    }
}

/// Chapters that start inside the audio, with their place on the strip.
struct PlayerChapters: Equatable {
    let starts: [TimeInterval]
    let titles: [String]
    let ticks: [Double]

    var isEmpty: Bool { starts.isEmpty }

    init(_ chapters: [MeetingTranscriptContent.Chapter], timeline: PlaybackTimeline) {
        let inside = chapters.filter { $0.startTime < timeline.duration }
        starts = inside.map(\.startTime)
        titles = inside.map(\.title)
        ticks = starts.map { timeline.fraction(at: $0) }
    }

    /// The chapter playing at `time`; a seek a frame short of a start counts as in it.
    func index(at time: TimeInterval) -> Int? {
        starts.lastIndex { $0 <= time + 0.05 }
    }
}

/// Each chapter's title starts at its tick and ends before the next one; a
/// title without room for a word is left to the transcript and Marginalia.
private struct PlayerChapterLabels: View {
    let chapters: PlayerChapters
    let current: Int?
    let onSeek: (Int) -> Void

    private static let inset: CGFloat = 5.5
    private static let minimumWidth: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            ForEach(chapters.titles.indices, id: \.self) { index in
                let left = chapters.ticks[index] * geo.size.width + Self.inset
                let next = (index + 1 < chapters.ticks.count ? chapters.ticks[index + 1] : 1) * geo.size.width
                let room = next - left - 6
                if room >= Self.minimumWidth {
                    Text(chapters.titles[index])
                        .font(.subheadline.weight(index == current ? .bold : .medium))
                        .foregroundStyle(index == current ? PVDesign.ink : PVDesign.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: room, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onSeek(index) }
                        .offset(x: left)
                }
            }
        }
        .frame(height: 14)
        // Marginalia's chapter list is the accessible way to jump.
        .accessibilityHidden(true)
    }
}

/// Who is speaking at the playhead and in which chapter: "You · Kickoff".
private struct PlayerReadout: View {
    let player: MeetingPlaybackSession
    let strip: MeetingPlayerStrip?
    let chapters: PlayerChapters

    var body: some View {
        let time = player.currentTime
        let voice = strip?.voice(at: time)
        let name = voice.map { VoiceName.of(isMe: $0.voice.isMe, name: $0.voice.name, label: $0.label) }
        let chapter = chapters.index(at: time).map { chapters.titles[$0] }
        let text = [name, chapter].compactMap(\.self).joined(separator: " · ")
        // Never truncated: the chapter goes first, then the whole readout.
        ViewThatFits(in: .horizontal) {
            line(voice, text)
            if let name { line(voice, name) }
            Color.clear.frame(width: 0)
        }
        .font(.callout)
        .foregroundStyle(PVDesign.ink3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
        .accessibilityIdentifier("player-readout")
    }

    private func line(_ voice: MeetingPlayerStrip.Voice?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let voice = voice?.voice { VoiceDot(tint: voice.tint, isOpen: !voice.isMe && voice.name == nil) }
            Text(verbatim: text).lineLimit(1)
        }
        .fixedSize()
    }
}

/// The current time in ink with equal digit cells; red stays with live status.
private struct PlayerClock: View {
    let player: MeetingPlaybackSession
    let size: CGFloat

    var body: some View {
        let now = ClockFormat.mmss(player.currentTime, paddedMinutes: false)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            DisplayTimeText(now, style: .clock(size: size))
                .foregroundStyle(PVDesign.ink)
                .accessibilityLabel(L10n.text("Current time"))
                .accessibilityValue(now)
                .accessibilityIdentifier("player-current-time")
            Text(verbatim: "/ \(ClockFormat.mmss(player.duration, paddedMinutes: false))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(PVDesign.ink3)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A quiet playback setting: plain while off, an ink pill while on. Without
/// room for its title it keeps the glyph and says the title on hover.
private struct PlayerToggleChip: View {
    let title: LocalizedStringKey
    let symbol: String
    let isOn: Bool
    let showsTitle: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                if showsTitle { Text(title) }
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isOn ? PVDesign.onInk : PVDesign.ink2)
            .padding(.horizontal, showsTitle ? 10 : 8)
            .frame(height: 26)
            .background(Capsule().fill(isOn ? PVDesign.ink : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
