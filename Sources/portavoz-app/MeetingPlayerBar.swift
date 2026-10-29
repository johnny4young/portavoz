import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI
import UniformTypeIdentifiers

/// The transport bar (M11): play/pause + a waveform scrubber over the mixed
/// timeline. Its own View so the scrubber's 5 fps updates don't re-render
/// the whole detail. Falls back to a plain slider until the waveform is
/// generated (or if the audio was unreadable).
struct MeetingPlayerBar: View {
    let player: MeetingPlaybackSession
    let waveform: [MeetingWaveformBucket]
    /// Speakers playback can focus on, "Me" first.
    let voices: [MeetingPlaybackVoice]
    let exportClip: @MainActor @Sendable (
        ClosedRange<TimeInterval>, URL
    ) async -> String?

    @State private var exporting = false
    @State private var exportError: String?

    private static let rates: [Float] = [1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("player-play-pause")

                skipButton(seconds: -15, symbol: "gobackward.15", identifier: "player-skip-back")
                skipButton(seconds: 15, symbol: "goforward.15", identifier: "player-skip-forward")

                HStack(spacing: 2) {
                    Text(ClockFormat.mmss(player.currentTime, paddedMinutes: false))
                        .accessibilityIdentifier("player-current-time")
                        .accessibilityValue(ClockFormat.mmss(player.currentTime, paddedMinutes: false))
                    Text(verbatim: "/ \(ClockFormat.mmss(player.duration, paddedMinutes: false))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                rateMenu
                Spacer()
                if voices.count > 1 { voiceMenu }
                optionsMenu
            }
            if waveform.isEmpty {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.1))
            } else {
                WaveformView(
                    buckets: waveform,
                    timeline: player.timeline,
                    currentTime: player.currentTime,
                    clipRange: player.clipRange,
                    onSeek: { player.seek(to: $0) })
            }
            if player.clipRange != nil { clipRow }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .alert(
            "Could not export",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func skipButton(seconds: TimeInterval, symbol: String, identifier: String) -> some View {
        Button {
            player.skip(by: seconds)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
        .accessibilityIdentifier(identifier)
    }

    private var rateMenu: some View {
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
            Text(Self.rateLabel(player.rate)).font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
        .accessibilityIdentifier("player-speed")
    }

    private var voiceMenu: some View {
        Menu {
            Button {
                player.focus(on: nil)
            } label: {
                focusLabel(L10n.text("Everyone"), selected: player.voiceFocus == nil)
            }
            .accessibilityIdentifier("player-voice-everyone")
            ForEach(voices) { voice in
                Button {
                    player.focus(on: voice.id, turns: voice.turns)
                } label: {
                    focusLabel(voice.name, selected: player.voiceFocus == voice.id)
                }
                .accessibilityIdentifier("player-voice-\(voice.label)")
            }
        } label: {
            Text(L10n.format("Play: %@", focusedVoiceName)).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Play only one person's turns")
        .accessibilityIdentifier("player-voice-focus")
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Skip silence", isOn: Binding(
                get: { player.skipSilence }, set: { player.skipSilence = $0 }))
                .accessibilityIdentifier("player-skip-silence")
            if player.canClearPlayback {
                Toggle("Reduce echo", isOn: Binding(
                    get: { player.clearPlayback }, set: { player.clearPlayback = $0 }))
                    .accessibilityIdentifier("player-clear-playback")
            }
            Divider()
            Button("Mark clip start") { player.markClipStart() }
                .accessibilityIdentifier("clip-mark-start")
            Button("Mark clip end") { player.markClipEnd() }
                .accessibilityIdentifier("clip-mark-end")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback options")
        .accessibilityIdentifier("player-options")
    }

    @ViewBuilder
    private func focusLabel(_ name: String, selected: Bool) -> some View {
        if selected {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    private var focusedVoiceName: String {
        voices.first { $0.id == player.voiceFocus }?.name ?? L10n.text("Everyone")
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
                    .foregroundStyle(.secondary)
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

/// One speaker playback can focus on.
struct MeetingPlaybackVoice: Identifiable, Equatable {
    let id: SpeakerID
    /// Stable speaker label ("Me", "S1") for accessibility identifiers.
    let label: String
    let name: String
    /// This speaker's turns in the current transcript.
    let turns: [ClosedRange<TimeInterval>]

    /// Speakers with transcribed turns, "Me" first.
    static func voices(speakers: [Speaker], segments: [TranscriptSegment]) -> [MeetingPlaybackVoice] {
        let turns = Dictionary(grouping: segments.filter { $0.endTime > $0.startTime }, by: \.speakerID)
        return speakers
            .filter { turns[$0.id] != nil }
            .sorted { ($0.isMe ? 0 : 1, $0.label) < ($1.isMe ? 0 : 1, $1.label) }
            .map { speaker in
                MeetingPlaybackVoice(
                    id: speaker.id,
                    label: speaker.label,
                    name: speaker.isMe ? L10n.text("Me") : speaker.displayName ?? speaker.label,
                    turns: turns[speaker.id, default: []].map { $0.startTime...$0.endTime })
            }
    }
}

/// The scrubber waveform (M11): peak-amplitude columns tinted by who was
/// talking (accent = you, gray = them) and dimmed past the playhead. Long
/// stretches without speech are drawn short with their length written in.
/// Click or drag anywhere to seek.
struct WaveformView: View {
    let buckets: [MeetingWaveformBucket]
    let timeline: PlaybackTimeline
    let currentTime: TimeInterval
    let clipRange: ClosedRange<TimeInterval>?
    /// Called with the meeting time under a click or drag.
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !buckets.isEmpty, timeline.duration > 0 else { return }
                if let clipRange {
                    let lower = timeline.fraction(at: clipRange.lowerBound) * size.width
                    let upper = timeline.fraction(at: clipRange.upperBound) * size.width
                    context.fill(
                        Path(roundedRect: CGRect(x: lower, y: 0, width: upper - lower, height: size.height),
                             cornerRadius: 3),
                        with: .color(PVDesign.accent.opacity(0.15)))
                }
                drawBars(in: &context, size: size)
                for gap in timeline.parts where gap.isGap {
                    drawGap(gap.range, in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    onSeek(timeline.time(at: value.location.x / max(1, geo.size.width)))
                })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(ClockFormat.mmss(currentTime, paddedMinutes: false)))
        .accessibilityIdentifier("player-waveform")
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let bucketLength = timeline.duration / Double(buckets.count)
        let progress = timeline.fraction(at: currentTime)
        let mid = size.height / 2
        let gaps = timeline.gaps
        for (index, bucket) in buckets.enumerated() {
            let start = Double(index) * bucketLength
            let center = start + bucketLength / 2
            guard !gaps.contains(where: { $0.contains(center) }) else { continue }
            let left = timeline.fraction(at: start) * size.width
            let right = timeline.fraction(at: start + bucketLength) * size.width
            let width = max(1, (right - left) * 0.6)
            let height = max(2, CGFloat(bucket.amplitude) * (size.height - 2))
            let rect = CGRect(
                x: left + (right - left - width) / 2, y: mid - height / 2,
                width: width, height: height)
            // Voices B: your channel is amber — the color IS the voice.
            let base: Color = bucket.microphoneDominant ? PVDesign.brandAmber : .gray
            let played = timeline.fraction(at: center) <= progress
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(base.opacity(played ? 0.9 : 0.3)))
        }
    }

    private func drawGap(
        _ gap: ClosedRange<TimeInterval>,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let left = timeline.fraction(at: gap.lowerBound) * size.width
        let right = timeline.fraction(at: gap.upperBound) * size.width
        var edges = Path()
        for x in [left + 1, right - 1] {
            edges.move(to: CGPoint(x: x, y: 6))
            edges.addLine(to: CGPoint(x: x, y: size.height - 6))
        }
        context.stroke(edges, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        let label = Text(Duration.seconds(gap.upperBound - gap.lowerBound)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        let resolved = context.resolve(label)
        let measured = resolved.measure(in: CGSize(width: max(0, right - left - 6), height: size.height))
        guard measured.width > 0, measured.width <= right - left - 6 else { return }
        context.draw(resolved, at: CGPoint(x: (left + right) / 2, y: size.height / 2))
    }
}
