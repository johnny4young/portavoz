import AppKit
import CoreText
import Synchronization
import SwiftUI

/// Fraunces, the display serif bundled under `Resources/Fonts/Fraunces`
/// (SIL OFL 1.1). Every lookup falls back to New York, so a missing file
/// changes the look, never the layout contract.
enum PVFont {
    static let family = "Fraunces"
    static let bundledFolder = "Fraunces"

    /// Registers the bundled faces for this process; safe to call again.
    @discardableResult
    static func registerBundledFonts(in bundle: Bundle = .main) -> Bool {
        guard let folder = bundle.url(forResource: bundledFolder, withExtension: nil) else { return false }
        return register(folder: folder)
    }

    static func register(folder: URL) -> Bool {
        let faces = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "ttf" }
        return !faces.isEmpty && faces.map(register(face:)).allSatisfy { $0 }
    }

    private static func register(face: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(face as CFURL, .process, &error) { return true }
        guard let error = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }

    /// The face with its variation axes set, or nil when `family` is not registered.
    static func ctFont(
        size: CGFloat, weight: CGFloat, soft: CGFloat, italic: Bool, family: String = family
    ) -> CTFont? {
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: [
                Axis.weight: weight,
                Axis.softness: soft,
                // Optical size follows the point size within the font's 9-144 range.
                Axis.opticalSize: min(max(size, 9), 144),
                Axis.wonky: 0
            ]
        ]
        if italic {
            attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitItalic.rawValue]
        }
        let font = CTFontCreateWithFontDescriptor(
            CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
        guard CTFontCopyFamilyName(font) as String == family else { return nil }
        if italic, !CTFontGetSymbolicTraits(font).contains(.traitItalic) { return nil }
        return font
    }

    /// A display font and, for upright faces, the width of its widest digit.
    struct Resolved: Sendable {
        let font: Font
        /// Nil when Fraunces is missing: the New York fallback has tabular digits.
        let digitCell: CGFloat?
    }

    static func resolve(
        size: CGFloat, weight: CGFloat, soft: CGFloat, italic: Bool, family: String = family
    ) -> Resolved {
        let key = Key(family: family, size: size, weight: weight, soft: soft, italic: italic)
        return cache.withLock { cache in
            if let cached = cache[key] { return cached }
            guard let font = ctFont(size: size, weight: weight, soft: soft, italic: italic, family: family) else {
                let fallback = Font.system(size: size, weight: fallbackWeight(weight), design: .serif)
                return Resolved(font: italic ? fallback.italic() : fallback.monospacedDigit(), digitCell: nil)
            }
            let resolved = Resolved(font: Font(font), digitCell: italic ? nil : widestDigit(in: font))
            cache[key] = resolved
            return resolved
        }
    }

    /// Fraunces has proportional figures only (no `tnum`), so ticking time
    /// sets each digit in a cell this wide.
    private static func widestDigit(in font: CTFont) -> CGFloat? {
        var characters = Array("0123456789".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return nil }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        return advances.map(\.width).max().map { ceil($0) }
    }

    static func fallbackWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    private enum Axis {
        static let weight = tag("wght")
        static let softness = tag("SOFT")
        static let opticalSize = tag("opsz")
        static let wonky = tag("WONK")

        private static func tag(_ name: String) -> Int {
            name.utf8.reduce(0) { $0 << 8 | Int($1) }
        }
    }

    private struct Key: Hashable {
        let family: String
        let size: CGFloat
        let weight: CGFloat
        let soft: CGFloat
        let italic: Bool
    }

    private static let cache = Mutex<[Key: Resolved]>([:])
}

/// One display type role from the design system: Fraunces for titles,
/// numerals and words as heard; SF stays on body text and controls.
struct PVDisplayStyle: Equatable, Sendable {
    var size: CGFloat
    var weight: CGFloat
    var soft: CGFloat = 40
    var italic = false
    /// Letter spacing in em.
    var tracking: CGFloat = -0.012
    /// The text style its size scales with under Dynamic Type.
    var relativeTo: Font.TextStyle

    /// The hero countdown.
    static let countdown = PVDisplayStyle(
        size: 172, weight: 340, soft: 100, tracking: -0.045, relativeTo: .largeTitle)
    /// Page and meeting titles.
    static let title = PVDisplayStyle(size: 40, weight: 480, relativeTo: .largeTitle)
    static let section = PVDisplayStyle(size: 21, weight: 520, relativeTo: .title2)
    /// Words quoted as they were heard.
    static let heard = PVDisplayStyle(size: 19, weight: 420, italic: true, tracking: 0, relativeTo: .title3)

    /// A running or scheduled time at a size the surrounding layout allows.
    static func clock(size: CGFloat) -> PVDisplayStyle {
        PVDisplayStyle(size: size, weight: 400, soft: 100, tracking: 0, relativeTo: .title2)
    }

    func resolved(size: CGFloat) -> PVFont.Resolved {
        PVFont.resolve(size: size, weight: weight, soft: soft, italic: italic)
    }
}

private struct PVDisplayModifier: ViewModifier {
    let style: PVDisplayStyle
    @ScaledMetric private var size: CGFloat

    init(_ style: PVDisplayStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(style.resolved(size: size).font)
            .tracking(size * style.tracking)
    }
}

extension View {
    /// Sets a display role, scaled with Dynamic Type.
    func pvDisplay(_ style: PVDisplayStyle) -> some View {
        modifier(PVDisplayModifier(style))
    }
}

/// Time set in a display role with every digit in an equal cell, so a
/// ticking clock keeps its width and its digits stay put.
struct DisplayTimeText: View {
    let text: String
    let style: PVDisplayStyle
    @ScaledMetric private var size: CGFloat

    init(_ text: String, style: PVDisplayStyle) {
        self.text = text
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    var body: some View {
        let resolved = style.resolved(size: size)
        if let cell = resolved.digitCell {
            HStack(spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .frame(width: character.isNumber ? cell : nil)
                }
            }
            .font(resolved.font)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
        } else {
            Text(verbatim: text).font(resolved.font)
        }
    }
}
