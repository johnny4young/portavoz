import AppKit
import SwiftUI
import XCTest

@testable import portavoz_app

@MainActor
final class PortavozMarkGlyphTests: XCTestCase {
    func testTheGlyphDrawsTheStrandsInItsColourInLightAndDark() async throws {
        for (scheme, isDark) in [(ColorScheme.light, false), (.dark, true)] {
            let renderer = ImageRenderer(
                content: PortavozMarkGlyph(color: PVDesign.onInk, height: 34).environment(\.colorScheme, scheme))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage, "\(scheme)"))
            let size = PortavozMark.glyphBox.size
            XCTAssertEqual(
                CGFloat(bitmap.pixelsWide) / CGFloat(bitmap.pixelsHigh), size.width / size.height, accuracy: 0.05)

            // The middle swell's centre, in icon units, mapped into the bitmap.
            let swell = try pixel(bitmap, iconX: 55, iconY: 50)
            XCTAssertGreaterThan(swell.alphaComponent, 0.9, "\(scheme)")
            let expected = PVTone.srgb(PVDesign.Tone.onInk.hex(dark: isDark))
            XCTAssertEqual(swell.redComponent, expected.redComponent, accuracy: 0.05, "\(scheme)")
            XCTAssertEqual(swell.blueComponent, expected.blueComponent, accuracy: 0.05, "\(scheme)")
            XCTAssertLessThan(try pixel(bitmap, iconX: 22, iconY: 41).alphaComponent, 0.1, "gaps stay clear")
        }
    }

    /// The top swell sits left, above its line; flipped it would land below.
    func testTheGlyphIsNotFlipped() async throws {
        let renderer = ImageRenderer(content: PortavozMarkGlyph(color: .black, height: 34))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertGreaterThan(try pixel(bitmap, iconX: 36, iconY: 28).alphaComponent, 0.9)
        XCTAssertLessThan(try pixel(bitmap, iconX: 36, iconY: 72).alphaComponent, 0.1)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, iconX: CGFloat, iconY: CGFloat) throws -> NSColor {
        let box = PortavozMark.glyphBox
        let x = (iconX - box.minX) / box.width * CGFloat(bitmap.pixelsWide)
        let y = (iconY - box.minY) / box.height * CGFloat(bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB))
    }
}
