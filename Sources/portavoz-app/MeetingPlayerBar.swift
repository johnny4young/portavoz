import AppKit
import AudioPlaybackKit
import SwiftUI
import UniformTypeIdentifiers

/// The transport bar (M11): play/pause + a waveform scrubber over the mixed
/// timeline. Its own View so the scrubber's 5 fps updates don't re-render
/// the whole detail. Falls back to a plain slider until the waveform is
/// generated (or if the audio was unreadable).
struct MeetingPlayerBar: View {
    let player: MeetingPlayer
    let waveform: [Waveform.Bucket]

    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
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

                Text(clock(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: Binding(get: { player.skipSilence }, set: { player.skipSilence = $0 })) {
                    Label("Skip silence", systemImage: "forward.fill")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Automatically skip silence during playback")
                Toggle(isOn: Binding(get: { player.onlyMyVoice }, set: { player.onlyMyVoice = $0 })) {
                    Label("Only my voice", systemImage: "person.wave.2")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(VoicePalette.me)
                .help("Play only your own turns — skips everyone else")
                Text(clock(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if waveform.isEmpty {
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.1))
            } else {
                WaveformView(
                    buckets: waveform,
                    progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                    clipRange: clipFractions,
                    onSeek: { player.seek(to: $0 * player.duration) })
            }
            clipRow
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

    /// Mark in/out at the playhead and export the range to an m4a clip.
    private var clipRow: some View {
        HStack(spacing: 8) {
            Button {
                player.markClipStart()
            } label: {
                Label("Start", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .controlSize(.small)
            .help("Mark clip start at the current playhead")
            .accessibilityIdentifier("clip-mark-start")

            Button {
                player.markClipEnd()
            } label: {
                Label("End", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .controlSize(.small)
            .help("Mark clip end at the current playhead")
            .accessibilityIdentifier("clip-mark-end")

            if let range = player.clipRange {
                Text("Clip \(clock(range.upperBound - range.lowerBound))")
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
            }
            Spacer()
        }
        .font(.caption)
    }

    /// The clip marks as 0…1 fractions for the waveform overlay.
    private var clipFractions: ClosedRange<Double>? {
        guard let range = player.clipRange, player.duration > 0 else { return nil }
        return (range.lowerBound / player.duration)...(range.upperBound / player.duration)
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
            do {
                try await AudioClipExporter.export(
                    channelFiles: player.channelFiles, range: range, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The scrubber waveform (M11): peak-amplitude columns tinted by who was
/// talking (accent = you, gray = them) and dimmed past the playhead. Click
/// or drag anywhere to seek.
struct WaveformView: View {
    let buckets: [Waveform.Bucket]
    /// Playback position as a 0…1 fraction of the duration.
    let progress: Double
    /// The selected clip as 0…1 fractions, shaded on the waveform.
    let clipRange: ClosedRange<Double>?
    /// Called with the seeked fraction (0…1) on click/drag.
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !buckets.isEmpty else { return }
                // Shade the selected clip range behind the bars.
                if let clipRange {
                    let rect = CGRect(
                        x: clipRange.lowerBound * size.width, y: 0,
                        width: (clipRange.upperBound - clipRange.lowerBound) * size.width,
                        height: size.height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 3),
                        with: .color(PVDesign.accent.opacity(0.15)))
                }
                let barWidth = size.width / CGFloat(buckets.count)
                let mid = size.height / 2
                for (index, bucket) in buckets.enumerated() {
                    let height = max(2, CGFloat(bucket.amplitude) * (size.height - 2))
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth + barWidth * 0.2,
                        y: mid - height / 2,
                        width: max(1, barWidth * 0.6),
                        height: height)
                    let played = (Double(index) + 0.5) / Double(buckets.count) <= progress
                    // Voices B: your channel is amber — the color IS the voice.
                    let base: Color = bucket.micDominant ? PVDesign.brandAmber : .gray
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(base.opacity(played ? 0.9 : 0.3)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    onSeek(min(1, max(0, value.location.x / max(1, geo.size.width))))
                })
        }
        .frame(height: 44)
    }
}
