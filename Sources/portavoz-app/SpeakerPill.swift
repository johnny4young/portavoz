import PortavozCore
import SwiftUI

/// One speaker as a `VoiceChip`: you in amber, named people in their stable
/// hue, unnamed voices with an open dot. Click to rename.
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

    private var name: String {
        speaker.map { $0.displayName ?? $0.label } ?? "?"
    }

    private var pill: some View {
        Button {
            if let speaker { onRename(speaker) }
        } label: {
            VoiceChip(
                voice: Self.voice(for: speaker, in: cast, colorScheme: colorScheme),
                name: name,
                isLinked: speaker?.personID != nil)
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
        .accessibilityLabel(name)
        .accessibilityValue(
            speaker?.personID == nil
                ? L10n.text("Meeting-only name")
                : L10n.text("Linked to a remembered person"))
    }

    static func voice(
        for speaker: Speaker?, in cast: [Speaker], colorScheme: ColorScheme
    ) -> VoiceChip.Voice {
        guard let speaker else { return .unnamed(VoicePalette.unnamed) }
        if speaker.isMe { return .you }
        let hue = VoicePalette.color(for: speaker, in: cast, colorScheme: colorScheme)
        return speaker.displayName == nil ? .unnamed(hue) : .named(hue)
    }
}
