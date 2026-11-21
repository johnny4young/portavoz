import AppKit
import ApplicationKit
import PortavozCore
import SwiftUI
import XCTest

@testable import portavoz_app

@MainActor
final class VoiceStripRenderingTests: XCTestCase {
    private let silence = VoiceColumns.silence

    /// You for the first half, silence for a quarter, a named voice for the rest.
    private var strip: VoiceStripColumns {
        let cast = VoiceCast(
            members: [
                .init(key: "me", isMe: true, name: nil, talkSeconds: 100),
                .init(key: "marta", name: "Marta", talkSeconds: 50),
                .init(key: "s2", name: nil, talkSeconds: 50)
            ],
            ordering: .talkShare)
        let columns = [UInt8](repeating: 0, count: 100) + [UInt8](repeating: silence, count: 50)
            + [UInt8](repeating: 1, count: 50)
        return VoiceStripColumns(
            columns: columns, tints: [.you, cast.tint(for: "marta"), .grey], cast: cast)
    }

    private func render(_ view: VoiceStrip, height: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: view.frame(width: 200, height: height).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 200)
        return NSBitmapImageRep(cgImage: image)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func assertTrack(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(color.alphaComponent, 0.3, file: file, line: line)
    }

    func testColumnsTakeTheirVoiceColourAndSilenceShowsTheTrack() async throws {
        let bitmap = try render(VoiceStrip(strip), height: 6)
        let you = try pixel(bitmap, 50)
        XCTAssertGreaterThan(you.alphaComponent, 0.9)
        XCTAssertGreaterThan(you.redComponent, you.blueComponent + 0.3)
        XCTAssertGreaterThan(you.redComponent, you.greenComponent)
        assertTrack(try pixel(bitmap, 125))
        let marta = try pixel(bitmap, 175)
        XCTAssertGreaterThan(marta.alphaComponent, 0.9)
        let distance = abs(marta.redComponent - you.redComponent)
            + abs(marta.greenComponent - you.greenComponent) + abs(marta.blueComponent - you.blueComponent)
        XCTAssertGreaterThan(distance, 0.2)
    }

    func testOnlyLeavesOtherVoicesAsTrack() async throws {
        let bitmap = try render(VoiceStrip(strip, only: 1), height: 6)
        assertTrack(try pixel(bitmap, 50))
        assertTrack(try pixel(bitmap, 125))
        XCTAssertGreaterThan(try pixel(bitmap, 175).alphaComponent, 0.9)
    }

    func testProgressDimsTheUnplayedPart() async throws {
        let bitmap = try render(VoiceStrip(strip, size: .player, progress: 0.15), height: 16)
        XCTAssertGreaterThan(try pixel(bitmap, 10).alphaComponent, 0.9)
        let ahead = try pixel(bitmap, 80)
        XCTAssertGreaterThan(ahead.alphaComponent, 0.3)
        XCTAssertLessThan(ahead.alphaComponent, 0.7)
        XCTAssertGreaterThan(ahead.redComponent, ahead.blueComponent)
    }

    func testEmptyAndInvalidStripsDrawOnlyTheTrack() async throws {
        let empty = try render(VoiceStrip(.empty, size: .player, progress: 0.5, ticks: [0.2]), height: 16)
        assertTrack(try pixel(empty, 150))
        let invalid = VoiceStripColumns(
            columns: [UInt8](repeating: 7, count: 200), tints: [.you], cast: strip.cast)
        assertTrack(try pixel(try render(VoiceStrip(invalid), height: 6), 100))
    }

    func testSpokenCastNamesVoicesInOrderAndGroupsTheUnnamed() async {
        func percent(_ share: Double) -> String {
            share.formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.current.locale))
        }
        XCTAssertEqual(
            VoiceStrip(strip).spokenCast,
            "\(L10n.text("You")) \(percent(0.5)), Marta \(percent(0.25)), \(L10n.format("Others · %d", 1))")
        XCTAssertEqual(VoiceStrip(.empty).spokenCast, "")
    }
}
