import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI

/// One colour token with its light and dark values (sRGB hex). The hex
/// stays readable so tests can check contrast on the exact values drawn.
/// `increased` replaces both values under Increase Contrast.
struct PVTone: Sendable {
    let light: UInt32
    let dark: UInt32
    var increased: (light: UInt32, dark: UInt32)?

    init(_ light: UInt32, _ dark: UInt32, increased: (light: UInt32, dark: UInt32)? = nil) {
        self.light = light
        self.dark = dark
        self.increased = increased
    }

    init(_ both: UInt32) { self.init(both, both) }

    func hex(dark isDark: Bool, increasedContrast: Bool = false) -> UInt32 {
        if increasedContrast, let increased { return isDark ? increased.dark : increased.light }
        return isDark ? dark : light
    }

    var nsColor: NSColor { nsColor(alpha: 1) }

    private static let appearances: [NSAppearance.Name] = [
        .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua
    ]

    func nsColor(alpha: CGFloat) -> NSColor {
        let light = PVTone.srgb(hex(dark: false), alpha: alpha)
        let dark = PVTone.srgb(hex(dark: true), alpha: alpha)
        let increasedLight = PVTone.srgb(hex(dark: false, increasedContrast: true), alpha: alpha)
        let increasedDark = PVTone.srgb(hex(dark: true, increasedContrast: true), alpha: alpha)
        return NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: PVTone.appearances) {
            case .accessibilityHighContrastAqua: increasedLight
            case .accessibilityHighContrastDarkAqua: increasedDark
            case .darkAqua: dark
            default: light
            }
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    func color(alpha: CGFloat) -> Color { Color(nsColor: nsColor(alpha: alpha)) }

    static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

/// The design system's tokens in Swift, mirroring
/// `docs/design/ds/tokens/colors.css`: ink on paper. Chrome carries no hue;
/// colour belongs to voices, red to the present, amber to you and green to
/// what Portavoz generates.
enum PVDesign {
    enum Tone {
        static let paper = PVTone(0xFBF7F2, 0x121615)
        static let paperSunk = PVTone(0xF4ECE3, 0x0E1211)
        static let card = PVTone(0xFFFDFA, 0x191E1C)
        static let raise = PVTone(0xFFFFFF, 0x222826)
        static let ink = PVTone(0x14201E, 0xEEEBE2)
        static let ink2 = PVTone(0x46534F, 0xB4BBB6)
        static let ink3 = PVTone(0x5C6763, 0x8D9692, increased: (0x46534F, 0xB4BBB6))
        static let onInk = PVTone(0xFBF7F2, 0x121615)
        static let now = PVTone(0xB93A22, 0xFF6A4C)
        static let nowBg = PVTone(0xFBE3DB, 0x3B1710)
        static let onNow = PVTone(0xFFFFFF, 0x220C05)
        static let green = PVTone(0x1F6F5C, 0x7FD1B9)
        static let greenBg = PVTone(0xE0EEE8, 0x15312B)
        static let ok = PVTone(0x1F6F5C, 0x6FCF97)
        static let you = PVTone(0xF2B33D)
        static let youInk = PVTone(0x8A5600, 0xF2B33D)
        static let youBg = PVTone(0xFCEBC2, 0x3A2C0C)
        static let onYou = PVTone(0x14201E)
    }

    // MARK: Surfaces

    static let paper = Tone.paper.color
    /// Sidebars and sunk wells.
    static let paperSunk = Tone.paperSunk.color
    static let card = Tone.card.color
    static let raise = Tone.raise.color

    // MARK: Ink

    static let ink = Tone.ink.color
    static let ink2 = Tone.ink2.color
    static let ink3 = Tone.ink3.color
    /// Text and glyphs on an ink fill.
    static let onInk = Tone.onInk.color
    /// Primary buttons, selection and focus. Reads the ink, never
    /// `PVDesign.accent`; macOS still paints native list selection and
    /// focus rings with the user's system accent.
    static let accent = ink

    // MARK: Meaning

    /// The present only: Record, Stop, the live edge and the now line.
    static let now = Tone.now.color
    static let nowBg = Tone.nowBg.color
    /// Labels on a red fill: Stop and the "Now" pill.
    static let onNow = Tone.onNow.color
    /// Portavoz speaking: briefs, summaries, suggestions, answers.
    static let green = Tone.green.color
    static let greenBg = Tone.greenBg.color
    /// Done, ready, connected.
    static let ok = Tone.ok.color
    /// Warnings and errors carry no hue: ink plus a glyph.
    static let caution = ink

    // MARK: You

    static let you = Tone.you.color
    /// Amber as text on paper.
    static let youInk = Tone.youInk.color
    static let youBg = Tone.youBg.color
    /// Text on an amber fill.
    static let onYou = Tone.onYou.color

    // MARK: Lines

    /// Hairlines, tracks and neutral chip fills.
    static let line = Tone.ink.color(alpha: 0.10)
    static let line2 = Tone.ink.color(alpha: 0.20)

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

    // MARK: Ink tints

    static let chipTint = 0.14        // selected row, chip capsule
    static let offerTint = 0.08       // secondary offer capsule

    // MARK: Offer chips

    static let chipOfferInk = ink3
    static let chipOfferBg = Tone.ink.color(alpha: 0.07)
}

/// «The colour is the voice»: you are always amber; every other speaker
/// gets one of five hues, assigned by order of appearance and persistent
/// per named person (a name hashes to the same hue in every meeting).
/// Chrome stays ink so voice is the only colour with meaning.
enum VoicePalette {
    /// Cobalt, Madder, Moss, Clay, Lagoon.
    static let hues: [PVTone] = [
        PVTone(0x3B6BD6, 0x7DA1F6),
        PVTone(0xC9437B, 0xEE7DAD),
        PVTone(0x6C8A28, 0xA8C759),
        PVTone(0xB25F36, 0xE09468),
        PVTone(0x2B8FA6, 0x5CC4D6)
    ]
    /// Grey for voices outside the cast: "them" in Insights and the far channel of the waveform.
    static let unnamedTone = PVTone(0x8791A0, 0x99A4B2)

    private static let lightColors = hues.map { Color(nsColor: PVTone.srgb($0.light)) }
    private static let darkColors = hues.map { Color(nsColor: PVTone.srgb($0.dark)) }

    static let me = PVDesign.you
    static let meContrast = PVDesign.onYou
    static let unnamed = unnamedTone.color

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

    /// Color for a speaker (index from `VoiceHue.index` — ApplicationKit,
    /// pure and tested).
    static func color(index: Int, colorScheme: ColorScheme) -> Color {
        let colors = colorScheme == .dark ? darkColors : lightColors
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// The color of one sidebar voice-mix slice: amber for you, a stable
    /// name hue for named speakers, cast order for the rest.
    static func color(
        for slice: LibraryVoiceMixSlice, colorScheme: ColorScheme
    ) -> Color {
        if slice.isMe { return me }
        return color(
            index: VoiceHue.index(name: slice.displayName, fallbackOrder: slice.order),
            colorScheme: colorScheme)
    }
}

extension View {
    /// Warning and error copy: ink, set apart by weight rather than hue.
    func cautionText() -> some View {
        foregroundStyle(PVDesign.caution).fontWeight(.semibold)
    }
}

/// One SF Symbol per concept (D536). Views name the concept, never the glyph,
/// so a symbol cannot drift between screens and `sparkles` stays reserved for
/// the ✦ chip that marks generated content (`ChipLabel`). Outlined symbols at
/// regular weight stand in for the design's 1.5 pt round-cap glyphs.
enum PVSymbol {
    // Navigation
    static let today = "calendar"
    static let ask = "text.bubble"
    static let insights = "chart.bar.xaxis"
    static let radar = "scope"
    // Assistants and generated work
    static let apuntador = "questionmark.bubble.fill"
    /// The same mark, outlined: Apuntador exists here but is switched off.
    static let apuntadorOff = "questionmark.bubble"
    static let generate = "wand.and.stars"
    static let proactive = "bell.badge"
    static let automations = "bolt.badge.checkmark"
    static let intelligence = "brain.head.profile"
    // Trust and state
    static let privacy = "lock.shield"
    static let success = "checkmark.circle.fill"
    static let warning = "exclamationmark.circle"
    static let error = "exclamationmark.triangle.fill"
    static let retry = "arrow.clockwise"
    static let correction = "pencil.line"
    static let translate = "translate"
    static let history = "clock.arrow.circlepath"
    static let commitment = "flag"
    // Recording
    static let record = "record.circle"
    static let stop = "stop.fill"
}
