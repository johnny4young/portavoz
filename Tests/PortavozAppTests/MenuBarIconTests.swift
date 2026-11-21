import AppKit
import XCTest

@testable import portavoz_app

final class MenuBarIconTests: XCTestCase {
    func testIdleIsATemplateSoTheMenuBarTintsIt() {
        XCTAssertTrue(MenuBarIcon.idle.isTemplate)
        XCTAssertFalse(MenuBarIcon.recording.isTemplate)
    }

    func testRecordingSwellIsTheLiveRedAndStrandsFollowTheMenuBar() throws {
        for (name, isDark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let bitmap = try render(MenuBarIcon.recording, appearance: name)
            let swell = try color(in: bitmap, 55, 50)
            let now = PVTone.srgb(PVDesign.Tone.now.hex(dark: isDark))
            XCTAssertEqual(swell.redComponent, now.redComponent, accuracy: 0.04, "\(name)")
            XCTAssertEqual(swell.greenComponent, now.greenComponent, accuracy: 0.04, "\(name)")

            let strand = try color(in: bitmap, 36, 33)
            XCTAssertGreaterThan(strand.alphaComponent, 0.5, "\(name)")
            if isDark {
                XCTAssertGreaterThan(strand.brightnessComponent, 0.8, "\(name)")
            } else {
                XCTAssertLessThan(strand.brightnessComponent, 0.3, "\(name)")
            }
        }
    }

    func testIdleMarkLeavesTheGapsBetweenStrandsClear() throws {
        let bitmap = try render(MenuBarIcon.idle, appearance: .aqua)
        XCTAssertLessThan(try color(in: bitmap, 22, 41).alphaComponent, 0.1)
        XCTAssertGreaterThan(try color(in: bitmap, 55, 50).alphaComponent, 0.9)
    }

    func testMiddleStrandSwellsWidestAndEverythingFitsTheGlyphBox() {
        let widths = PortavozMark.Strand.allCases.map { PortavozMark.swell($0).boundingBox.height }
        XCTAssertEqual(widths.max(), PortavozMark.swell(.middle).boundingBox.height)
        let ink = PortavozMark.Strand.allCases.reduce(CGRect.null) {
            $0.union(PortavozMark.line($1).boundingBox).union(PortavozMark.swell($1).boundingBox)
        }.insetBy(dx: -PortavozMark.glyphStrokeWidth / 2, dy: -PortavozMark.glyphStrokeWidth / 2)
        XCTAssertTrue(PortavozMark.glyphBox.contains(ink))
        XCTAssertTrue(PortavozMark.iconBox.contains(PortavozMark.glyphBox))
    }

    /// The brand renderer cannot import the app, so its copies of the tokens
    /// are checked here.
    func testBrandRendererUsesTheDesignTokens() throws {
        let script = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("scripts/render-brand.swift"),
            encoding: .utf8)
        typealias Tone = PVDesign.Tone
        let tones = [Tone.you, Tone.paper, Tone.card, Tone.ink, Tone.ink2].map(\.light)
        let strands = VoicePalette.hues.prefix(2).flatMap { [$0.light, $0.dark] }
        for hex in tones + strands {
            let literal = String(format: "#%06X", hex)
            XCTAssertTrue(script.contains(literal), literal)
        }
    }

    // MARK: - Helpers

    private static let scale: CGFloat = 4

    /// The pixel under a point in icon units (bitmap origin top-left).
    private func color(in bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        let size = MenuBarIcon.size
        let point = CGPoint(x: x, y: y)
            .applying(PortavozMark.glyphTransform(into: CGRect(origin: .zero, size: size)))
        return try XCTUnwrap(bitmap.colorAt(
            x: Int(point.x * Self.scale), y: Int((size.height - point.y) * Self.scale)))
    }

    private func render(_ image: NSImage, appearance name: NSAppearance.Name) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        let size = MenuBarIcon.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * Self.scale),
            pixelsHigh: Int(size.height * Self.scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
