import ApplicationKit
import SwiftUI

struct MeetingDetailPlayerValues {
    let player: MeetingPlaybackSession?
    let waveform: [MeetingWaveformBucket]
    let canCompressAudio: Bool
    let isCompressingAudio: Bool
    let compressionMessage: String?
}

struct MeetingDetailPlayerActions {
    let exportClip: @MainActor @Sendable (
        ClosedRange<TimeInterval>, URL
    ) async -> String?
    let compressAudio: @MainActor () -> Void
}

/// The complete docked playback surface for one reviewed meeting.
///
/// Playback state remains owned by the route model and audio operations remain
/// in ApplicationKit. This section owns only playback presentation and emits
/// explicit clip-export or compression intents.
struct MeetingDetailPlayerSection: View {
    let values: MeetingDetailPlayerValues
    let actions: MeetingDetailPlayerActions

    var body: some View {
        Group {
            if let player = values.player {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    MeetingPlayerBar(
                        player: player,
                        waveform: values.waveform,
                        exportClip: actions.exportClip)
                    compressionRow
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-player-section")
    }

    @ViewBuilder
    private var compressionRow: some View {
        if values.canCompressAudio
            || values.isCompressingAudio
            || values.compressionMessage != nil {
            HStack(spacing: 8) {
                Button(action: actions.compressAudio) {
                    if values.isCompressingAudio {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Compressing…")
                        }
                    } else {
                        Label("Compress audio (AAC)", systemImage: "arrow.down.circle")
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("detail-compress-audio")
                .disabled(!values.canCompressAudio)
                .help(
                    "Converts audio to AAC to save disk space, with no audible loss for speech")
                if let compressionMessage = values.compressionMessage {
                    Text(compressionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
