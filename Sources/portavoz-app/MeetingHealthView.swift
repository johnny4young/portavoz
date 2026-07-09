import IntelligenceKit
import PortavozCore
import SwiftUI

/// Meeting-health panel (M13b): talk time per speaker, questions and
/// interruptions — computed locally from the attributed transcript, no
/// model involved. Collapsed into a compact block under the summary.
struct MeetingHealthView: View {
    let speakers: [Speaker]
    let segments: [TranscriptSegment]

    private var health: MeetingHealth { MeetingHealth.compute(segments: segments) }

    private func name(_ id: SpeakerID) -> String {
        guard let speaker = speakers.first(where: { $0.id == id }) else { return "?" }
        if speaker.isMe { return L10n.text("Me") }
        return speaker.displayName ?? speaker.label
    }

    var body: some View {
        let health = health
        if health.stats.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Meeting health", systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    if health.questionsTotal > 0 {
                        chip("questionmark.bubble", "\(health.questionsTotal)")
                            .help("Questions asked in the meeting")
                    }
                    if health.interruptionsTotal > 0 {
                        chip("exclamationmark.bubble", "\(health.interruptionsTotal)")
                            .help("Times someone started talking over someone else")
                    }
                }
                ForEach(health.stats) { stat in
                    speakerRow(stat)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func speakerRow(_ stat: MeetingHealth.SpeakerStat) -> some View {
        HStack(spacing: 8) {
            Text(name(stat.speakerID))
                .font(.caption.weight(.semibold))
                .frame(width: 76, alignment: .trailing)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: max(3, geometry.size.width * stat.share))
                }
            }
            .frame(height: 8)
            Text(minutes(stat.speechSeconds) + " · \(Int((stat.share * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if stat.interruptionsMade > 0 {
                chip("exclamationmark.bubble", "\(stat.interruptionsMade)")
                    .help("Interruptions made by this speaker")
            }
        }
    }

    private func chip(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
