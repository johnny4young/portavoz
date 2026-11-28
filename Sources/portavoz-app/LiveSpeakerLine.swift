import ApplicationKit
import SwiftUI

/// Who is speaking now and who spoke just before, read off the live Voices
/// table: "You speaking · then S1, S2". The menu bar and the HUD share it.
struct LiveSpeakerLine: Equatable {
    let lead: LiveVoiceTable.Row
    let then: [LiveVoiceTable.Row]
    let voiceCount: Int

    init?(stage: LiveVoiceStage, cast: VoiceCast) {
        let rows = LiveVoiceTable(stage: stage, cast: cast).rows
        guard let lead = rows.first else { return nil }
        self.lead = lead
        then = Array(rows.dropFirst().prefix(2))
        voiceCount = stage.voiceCount
    }

    var name: String { LiveVoiceName.of(lead.voice) }

    /// After the bold name: "speaking · then S1, S2", or "speaking".
    var speakingDetail: String {
        guard let thenText else { return L10n.text("speaking") }
        return [L10n.text("speaking"), thenText].joined(separator: " · ")
    }

    /// Nobody speaking: "Last heard: S1, You, S2".
    var lastHeard: String {
        L10n.format("Last heard: %@", Self.names([lead] + then))
    }

    /// "You speaking" or "Last heard: S1, You".
    var leadSpoken: String {
        lead.isSpeaking ? "\(name) \(L10n.text("speaking"))" : lastHeard
    }

    var voices: String? {
        switch voiceCount {
        case 0: nil
        case 1: L10n.text("1 voice")
        default: L10n.format("%d voices", voiceCount)
        }
    }

    /// "You speaking, then S1, S2" or "Last heard: S1, You".
    var spoken: String {
        guard lead.isSpeaking else { return lastHeard }
        return [leadSpoken, thenText].compactMap(\.self).joined(separator: ", ")
    }

    /// The bold name in ink, the rest in ink 3.
    var styled: AttributedString {
        var rest = AttributedString(lead.isSpeaking ? " " + speakingDetail : lastHeard)
        rest.foregroundColor = PVDesign.ink3
        guard lead.isSpeaking else { return rest }
        var name = AttributedString(name)
        name.foregroundColor = PVDesign.ink
        name.inlinePresentationIntent = .stronglyEmphasized
        return name + rest
    }

    private var thenText: String? {
        then.isEmpty ? nil : L10n.format("then %@", Self.names(then))
    }

    private static func names(_ rows: [LiveVoiceTable.Row]) -> String {
        rows.map { LiveVoiceName.of($0.voice) }.joined(separator: ", ")
    }
}

/// Bars for whoever speaks now, else their dot.
struct LiveSpeakerGlyph: View {
    let row: LiveVoiceTable.Row
    var dotSize: CGFloat = 8

    var body: some View {
        if row.isSpeaking {
            SpeakingBars(tint: row.voice.tint)
        } else {
            VoiceDot(tint: row.voice.tint, size: dotSize, isOpen: !row.voice.isMe && row.voice.name == nil)
                .frame(width: 14)
        }
    }
}

/// Who is speaking beside a strip of the call so far. The floating panel's only
/// reader of the live voices, so a refresh redraws this slot alone; the fixed
/// name slot keeps the row still when the speaker changes.
struct RecordingHUDSpeaker: View {
    let controller: RecordingController

    var body: some View {
        let model = controller.liveVoices
        let line = LiveSpeakerLine(stage: model.stage, cast: model.cast)
        HStack(spacing: 6) {
            if let line {
                LiveSpeakerGlyph(row: line.lead)
                Text(line.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(PVDesign.ink)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
            }
            RecordingNowStrip(strip: model.stage.strip(cast: model.cast), size: .card)
                .frame(width: 96)
                .accessibilityIdentifier("recording-hud-strip")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line?.leadSpoken ?? "")
        .accessibilityIdentifier("recording-hud-speaker")
    }
}
