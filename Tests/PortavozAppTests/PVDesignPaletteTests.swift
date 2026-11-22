import AppKit
import ApplicationKit
import XCTest

@testable import portavoz_app

final class PVDesignPaletteTests: XCTestCase {
    private typealias Tone = PVDesign.Tone

    /// Every text/background pair the System board specifies, checked on the
    /// exact hex values the app draws.
    private let textPairs: [(name: String, text: PVTone, background: PVTone)] = [
        ("ink on paper", Tone.ink, Tone.paper),
        ("ink on sunk paper", Tone.ink, Tone.paperSunk),
        ("ink on card", Tone.ink, Tone.card),
        ("ink on raised card", Tone.ink, Tone.raise),
        ("ink 2 on paper", Tone.ink2, Tone.paper),
        ("ink 3 on paper", Tone.ink3, Tone.paper),
        ("ink 3 on sunk paper", Tone.ink3, Tone.paperSunk),
        ("ink 3 on card", Tone.ink3, Tone.card),
        ("primary button label", Tone.onInk, Tone.ink),
        ("stop button and Now label", Tone.onNow, Tone.now),
        ("ink on the generated tint", Tone.ink, Tone.greenBg),
        ("secondary text on the generated tint", Tone.ink2, Tone.greenBg),
        ("tertiary text on the generated tint", Tone.ink3, Tone.greenBg),
        ("commitment caption on card", Tone.ink3, Tone.card),
        ("now on paper", Tone.now, Tone.paper),
        ("now on its tint", Tone.now, Tone.nowBg),
        ("green on paper", Tone.green, Tone.paper),
        ("green on its tint", Tone.green, Tone.greenBg),
        ("ok on paper", Tone.ok, Tone.paper),
        ("you as text on paper", Tone.youInk, Tone.paper),
        ("you as text on its tint", Tone.youInk, Tone.youBg),
        ("text on an amber fill", Tone.onYou, Tone.you),
        ("sidebar section header", Tone.ink3, Tone.paperSunk),
        ("secondary text on a raised row", Tone.ink3, Tone.raise)
    ]

    func testEveryBoardTextPairMeetsAAInBothAppearances() {
        for dark in [false, true] {
            for increased in [false, true] {
                for pair in textPairs {
                    let ratio = Self.contrast(
                        pair.text.hex(dark: dark, increasedContrast: increased),
                        pair.background.hex(dark: dark, increasedContrast: increased))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(pair.name) is \(String(format: "%.2f", ratio)):1 "
                            + "(\(dark ? "dark" : "light")\(increased ? ", increased contrast" : ""))")
                }
            }
        }
    }

    /// Text on ink tints over sunk paper, the darkest surface they sit on:
    /// offer chips and the selected Settings category's subtitle.
    func testSidebarTintedLabelsMeetAA() {
        let pairs: [(name: String, text: PVTone, alpha: Double)] = [
            ("offer chip", Tone.ink2, PVDesign.chipOfferAlpha),
            ("selected settings subtitle", Tone.ink2, PVDesign.chipTint)
        ]
        for dark in [false, true] {
            for pair in pairs {
                let tint = Self.blend(Tone.ink.hex(dark: dark), alpha: pair.alpha, over: Tone.paperSunk.hex(dark: dark))
                XCTAssertGreaterThanOrEqual(
                    Self.contrast(pair.text.hex(dark: dark), tint), 4.5, "\(pair.name) (\(dark ? "dark" : "light"))")
            }
        }
    }

    /// Native switches and checkboxes draw a white knob or tick on the tint.
    func testControlTintKeepsTheWhiteKnobAndTheTrackVisible() {
        for dark in [false, true] {
            let track = Tone.control.hex(dark: dark)
            XCTAssertGreaterThanOrEqual(Self.contrast(0xFFFFFF, track), 3, dark ? "dark knob" : "light knob")
            XCTAssertGreaterThanOrEqual(Self.contrast(track, Tone.paper.hex(dark: dark)), 3)
        }
    }

    func testIdleOnboardingBarsKeepNonTextContrast() {
        for dark in [false, true] {
            let paper = Tone.paper.hex(dark: dark)
            let bar = Self.blend(Tone.ink3.hex(dark: dark), alpha: FirstListenWaveform.idleOpacity, over: paper)
            XCTAssertGreaterThanOrEqual(Self.contrast(bar, paper), 3)
        }
    }

    func testDarkVoiceHuesReadOnNight() {
        for tone in VoicePalette.hues + [VoicePalette.unnamedTone, Tone.you] {
            XCTAssertGreaterThanOrEqual(Self.contrast(tone.dark, Tone.paper.dark), 4.5)
        }
    }

    func testUnplayedVoicesStayApartFromTheDarkTrack() {
        let track = Self.blend(Tone.ink.dark, alpha: 0.1, over: Tone.paper.dark)
        for size in [VoiceStrip.Size.resume, .player] {
            let alpha = size.unplayedOpacity(.dark)
            for tone in VoicePalette.hues + [VoicePalette.unnamedTone, Tone.you] {
                let run = Self.blend(tone.dark, alpha: alpha, over: track)
                XCTAssertGreaterThanOrEqual(Self.contrast(run, track), 3, "\(size) \(String(tone.dark, radix: 16))")
            }
        }
    }

    func testVoicePaletteMatchesTheSharedHueCount() {
        XCTAssertEqual(VoicePalette.hues.count, VoiceHue.paletteSize)
    }

    func testDynamicTonesResolvePerAppearance() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(Self.hex(of: Tone.ink.nsColor, in: aqua), Tone.ink.light)
        XCTAssertEqual(Self.hex(of: Tone.ink.nsColor, in: dark), Tone.ink.dark)
        XCTAssertEqual(Self.hex(of: Tone.ink3.nsColor, in: aqua), Tone.ink3.light)
        // AppKit cannot build a high-contrast appearance outside the system,
        // so the Increase Contrast branch is checked on the resolver.
        XCTAssertEqual(Tone.ink3.hex(dark: false, increasedContrast: true), Tone.ink2.light)
        XCTAssertEqual(Tone.ink3.hex(dark: true, increasedContrast: true), Tone.ink2.dark)
    }

    private static func hex(of color: NSColor, in appearance: NSAppearance) -> UInt32? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let resolved else { return nil }
        let r = UInt32((resolved.redComponent * 255).rounded())
        let g = UInt32((resolved.greenComponent * 255).rounded())
        let b = UInt32((resolved.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
    }

    private static func blend(_ top: UInt32, alpha: Double, over bottom: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let mixed = alpha * Double((top >> shift) & 0xFF) + (1 - alpha) * Double((bottom >> shift) & 0xFF)
            return UInt32(mixed.rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
