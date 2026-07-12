import PortavozCore
import SwiftUI

/// One speaker chip, painted with the speaker's VOICE color (design
/// system, voices direction B): "Me" is always solid amber; everyone else
/// wears their stable hue. Click to rename — the M3 "editable speaker
/// pills" acceptance piece.
struct SpeakerPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let speaker: Speaker?
    /// The meeting's cast — hue assignment for unnamed speakers follows
    /// their order of appearance within it.
    var cast: [Speaker] = []
    let onRename: (Speaker) -> Void

    var body: some View {
        Button {
            if let speaker { onRename(speaker) }
        } label: {
            Text(speaker.map { $0.displayName ?? $0.label } ?? "?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker?.isMe == true ? VoicePalette.meContrast : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(pillBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
    }

    private var pillBackground: Color {
        guard let speaker else { return Color.secondary.opacity(0.18) }
        if speaker.isMe { return VoicePalette.me }
        return VoicePalette.color(for: speaker, in: cast, colorScheme: colorScheme)
            .opacity(0.26)
    }
}
