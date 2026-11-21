import ApplicationKit
import PortavozCore
import SwiftUI

/// One speaker as a `VoiceChip`, coloured by the meeting's `VoiceCast`.
/// Click to rename.
struct SpeakerPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let speaker: Speaker?
    let cast: VoiceCast
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
        for speaker: Speaker?, in cast: VoiceCast, colorScheme: ColorScheme
    ) -> VoiceChip.Voice {
        guard let speaker else { return .unnamed(VoicePalette.unnamed) }
        if speaker.isMe { return .you }
        let colour = VoicePalette.color(cast.tint(for: speaker), colorScheme: colorScheme)
        return speaker.displayName == nil ? .unnamed(colour) : .named(colour)
    }
}
