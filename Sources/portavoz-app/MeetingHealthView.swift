import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// Meeting-health panel (M13b): questions and interruptions per speaker,
/// computed locally from the attributed transcript, no model involved. Talk
/// share and time live in the header's Voices table.
struct MeetingHealthView: View {
    let speakers: [Speaker]
    let segments: [TranscriptSegment]
    let voiceCast: VoiceCast

    private var health: MeetingHealth { MeetingHealth.compute(segments: segments) }

    private func name(_ id: SpeakerID) -> String {
        speakers.first(where: { $0.id == id }).map(VoiceName.of(_:)) ?? "?"
    }

    var body: some View {
        let health = health
        if health.stats.count >= 2 {
            let active = health.stats.filter { $0.questions > 0 || $0.interruptionsMade > 0 }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Meeting health", systemImage: "waveform.path.ecg")
                        .font(.headline)
                        .accessibilityIdentifier("detail-meeting-health")
                    Spacer()
                    if health.questionsTotal > 0 {
                        chip(PVSymbol.apuntador, "\(health.questionsTotal)")
                            .help("Counts the questions asked in this meeting")
                    }
                    if health.interruptionsTotal > 0 {
                        chip("exclamationmark.bubble", "\(health.interruptionsTotal)")
                            .help("Counts how often someone talked over someone else")
                    }
                }
                if active.isEmpty {
                    Text("No questions or interruptions.")
                        .font(.caption)
                        .foregroundStyle(PVDesign.ink3)
                }
                ForEach(active) { speakerRow($0) }
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func speakerRow(_ stat: MeetingHealth.SpeakerStat) -> some View {
        HStack(spacing: 6) {
            VoiceDot(tint: voiceCast.tint(for: stat.speakerID))
            Text(name(stat.speakerID))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PVDesign.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if stat.questions > 0 {
                chip(PVSymbol.apuntador, "\(stat.questions)")
                    .help("Counts the questions this speaker asked")
            }
            if stat.interruptionsMade > 0 {
                chip("exclamationmark.bubble", "\(stat.interruptionsMade)")
                    .help("Counts how often this speaker interrupted")
            }
        }
    }

    private func chip(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.ink3)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
