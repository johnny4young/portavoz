import ApplicationKit
import SwiftUI

struct MeetingDetailPlayerValues {
    let player: MeetingPlaybackSession?
    let strip: MeetingPlayerStrip?
    let chapters: [MeetingTranscriptContent.Chapter]
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
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(PVDesign.line)
                        .frame(height: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        MeetingPlayerBar(
                            player: player,
                            strip: values.strip,
                            chapters: values.chapters,
                            exportClip: actions.exportClip)
                        compressionRow
                        trimRow
                    }
                    .padding(.vertical, 10)
                    .meetingPageColumn()
                }
                .background(PVDesign.card)
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
                .foregroundStyle(PVDesign.ink3)
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
                .foregroundStyle(PVDesign.ink3)
                .accessibilityIdentifier("detail-compress-message")
        }
    }
}
