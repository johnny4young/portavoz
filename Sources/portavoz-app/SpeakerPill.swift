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
    var accessibilityIdentifier: String?
    let onRename: (Speaker) -> Void

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            pill.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            pill
        }
    }

    private var pill: some View {
        Button {
            if let speaker { onRename(speaker) }
        } label: {
            HStack(spacing: 4) {
                Text(speaker.map { $0.displayName ?? $0.label } ?? "?")
                if speaker?.personID != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PVDesign.accent)
                }
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker?.isMe == true ? VoicePalette.meContrast : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(pillBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
        .accessibilityLabel(speaker.map { $0.displayName ?? $0.label } ?? "?")
        .accessibilityValue(
            speaker?.personID == nil
                ? L10n.text("Meeting-only name")
                : L10n.text("Linked to a remembered person"))
    }

    private var pillBackground: Color {
        guard let speaker else { return Color.secondary.opacity(0.18) }
        if speaker.isMe { return VoicePalette.me }
        return VoicePalette.color(for: speaker, in: cast, colorScheme: colorScheme)
            .opacity(0.26)
    }
}
