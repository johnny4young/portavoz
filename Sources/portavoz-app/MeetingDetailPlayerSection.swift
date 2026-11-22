import ApplicationKit
import SwiftUI

struct MeetingDetailPlayerValues {
    let player: MeetingPlaybackSession?
    let waveform: [MeetingWaveformBucket]
    let isCompressingAudio: Bool
    let compressionMessage: String?
    let isTrimmingAudio: Bool
    let trimMessage: String?
}

struct MeetingDetailPlayerActions {
    let exportClip: @MainActor @Sendable (
        ClosedRange<TimeInterval>, URL
    ) async -> String?
}

/// The complete docked playback surface for one reviewed meeting.
///
/// Playback state remains owned by the route model and audio operations remain
/// in ApplicationKit. This section owns only playback presentation, the clip
/// export intent and the progress of audio changes started from the toolbar.
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
                    trimRow
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-player-section")
    }

    @ViewBuilder
    private var trimRow: some View {
        if values.isTrimmingAudio {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Removing silence…")
            }
            .font(.caption)
            .accessibilityIdentifier("detail-trim-progress")
        } else if let trimMessage = values.trimMessage {
            Text(trimMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detail-trim-message")
        }
    }

    @ViewBuilder
    private var compressionRow: some View {
        if values.isCompressingAudio {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Compressing…")
            }
            .font(.caption)
            .accessibilityIdentifier("detail-compress-progress")
        } else if let compressionMessage = values.compressionMessage {
            Text(compressionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detail-compress-message")
        }
    }
}
