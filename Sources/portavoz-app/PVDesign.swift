import IntegrationsKit
import PortavozCore
import SwiftUI

/// The design system's tokens in Swift — the single source the app reads;
/// values mirror `docs/design/ds/tokens/*.css` (authored in Claude Design,
/// pulled to the repo). When a value changes there, it changes HERE and
/// nowhere else in the app.
enum PVDesign {
    /// The one accent of the product (the DS's stance on the accent debt):
    /// system indigo — #5856D6 light / #5E5CE6 dark, exactly the DS tokens.
    /// UI that means "the accent" reads THIS (or inherits the root `.tint`),
    /// never `Color.accentColor`, which follows the user's system accent.
    /// macOS still paints native list selection and focus rings itself.
    static let accent = Color.indigo

    // MARK: Spacing (12/16/24 core scale)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12   // tile padding, sidebar gutters
    static let space4: CGFloat = 16   // card padding, detail padding
    static let space6: CGFloat = 24   // page padding

    // MARK: Radii (8 insets · 10 tiles · 12 cards · 14 panels · capsules)

    static let radiusSmall: CGFloat = 8
    static let radiusTile: CGFloat = 10
    static let radiusCard: CGFloat = 12
    static let radiusPanel: CGFloat = 14

    // MARK: Accent tints (chips and pills ride the accent, per the DS)

    static let chipTint = 0.14        // suggestion chip capsule
    static let offerTint = 0.08       // secondary offer capsule
    static let mePillTint = 0.18      // legacy "Me" pill (pre voices-B)

    // MARK: Brand (the icon's world — web + Aurora doses)

    static let brandAmber = Color(red: 0xFD / 255, green: 0xBF / 255, blue: 0x47 / 255)
    static let brandViolet = Color(red: 0x52 / 255, green: 0x26 / 255, blue: 0xBF / 255)
    static let brandSlate = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x20 / 255)

    /// Amber's readable counterpart for text ON amber (voice-me-contrast).
    static let amberContrast = Color(red: 0x4A / 255, green: 0x38 / 255, blue: 0x00 / 255)
}

/// Voices direction B — «el color ES la voz». The user's voice is ALWAYS
/// solid amber; every other speaker gets a stable hue, assigned by
/// order of appearance and persistent per NAMED person (a name hashes to
/// the same hue in every meeting). The UI stays neutral so voice is the
/// only meaningful color; indigo stays reserved for system interaction.
enum VoicePalette {
    /// --voice-1…6 (light) / dark variants lift luminance one step for AA.
    private static let lightHues: [Color] = [
        Color(red: 0x8B / 255, green: 0x7C / 255, blue: 0xF0 / 255),
        Color(red: 0x4A / 255, green: 0xA8 / 255, blue: 0xD8 / 255),
        Color(red: 0x3F / 255, green: 0xBF / 255, blue: 0x9A / 255),
        Color(red: 0xE0 / 255, green: 0x7A / 255, blue: 0x9B / 255),
        Color(red: 0xB9 / 255, green: 0x8A / 255, blue: 0xE0 / 255),
        Color(red: 0xD8 / 255, green: 0xA2 / 255, blue: 0x4A / 255)
    ]
    private static let darkHues: [Color] = [
        Color(red: 0x9D / 255, green: 0x8F / 255, blue: 0xFA / 255),
        Color(red: 0x5C / 255, green: 0xB8 / 255, blue: 0xE6 / 255),
        Color(red: 0x4F / 255, green: 0xD0 / 255, blue: 0xAB / 255),
        Color(red: 0xEF / 255, green: 0x8F / 255, blue: 0xAE / 255),
        Color(red: 0xC8 / 255, green: 0x9A / 255, blue: 0xEE / 255),
        Color(red: 0xE6 / 255, green: 0xB2 / 255, blue: 0x5E / 255)
    ]

    static let me = PVDesign.brandAmber
    static let meContrast = PVDesign.amberContrast

    /// The voice color for a speaker within a meeting's cast: amber for
    /// "Me"; named people by stable name hash; S-labels by cast order.
    static func color(
        for speaker: Speaker, in cast: [Speaker], colorScheme: ColorScheme
    ) -> Color {
        if speaker.isMe { return me }
        let others = cast.filter { !$0.isMe }
        let order = others.firstIndex { $0.id == speaker.id } ?? 0
        return color(
            index: VoiceHue.index(name: speaker.displayName, fallbackOrder: order),
            colorScheme: colorScheme)
    }

    /// Color for a speaker (index from `VoiceHue.index` — IntegrationsKit,
    /// pure and tested).
    static func color(index: Int, colorScheme: ColorScheme) -> Color {
        let hues = colorScheme == .dark ? darkHues : lightHues
        return hues[((index % 6) + 6) % 6]
    }
}
