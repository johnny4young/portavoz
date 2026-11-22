import AppKit
import CoreText
import SwiftUI
import XCTest

@testable import portavoz_app

final class PVFontTests: XCTestCase {
    private static let fontFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts/Fraunces")

    func testTheShippedFolderCarriesBothFacesAndTheLicense() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fontFolder.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertEqual(names, [
            "Fraunces-Italic[SOFT,WONK,opsz,wght].ttf", "Fraunces[SOFT,WONK,opsz,wght].ttf", "OFL.txt"
        ])
        let license = try String(contentsOf: Self.fontFolder.appendingPathComponent("OFL.txt"), encoding: .utf8)
        XCTAssertTrue(license.contains("SIL Open Font License, Version 1.1"))
    }

    func testTheFolderRegistersAndResolvesTheRequestedAxes() throws {
        XCTAssertTrue(PVFont.register(folder: Self.fontFolder))
        XCTAssertTrue(PVFont.register(folder: Self.fontFolder), "registering twice still succeeds")

        let style = PVDisplayStyle.countdown
        let font = try XCTUnwrap(PVFont.ctFont(
            size: style.size, weight: style.weight, soft: style.soft, italic: false))
        XCTAssertEqual(CTFontCopyFamilyName(font) as String, "Fraunces")
        let variation = try XCTUnwrap(CTFontCopyVariation(font) as? [Int: Double])
        XCTAssertEqual(variation[0x7767_6874], 340)
        XCTAssertEqual(variation[0x534F_4654], 100)
        XCTAssertEqual(variation[0x6F70_737A], 144, "optical size clamps to the font's range")
        XCTAssertEqual(variation[0x574F_4E4B], 0)

        let heard = try XCTUnwrap(PVFont.ctFont(size: 19, weight: 420, soft: 40, italic: true))
        XCTAssertTrue(CTFontGetSymbolicTraits(heard).contains(.traitItalic))
        XCTAssertTrue((CTFontCopyPostScriptName(heard) as String).contains("Italic"))
    }

    func testAFolderMissingTheItalicFaceDoesNotCountAsRegistered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let upright = "Fraunces[SOFT,WONK,opsz,wght].ttf"
        try FileManager.default.copyItem(
            at: Self.fontFolder.appendingPathComponent(upright), to: folder.appendingPathComponent(upright))

        XCTAssertFalse(PVFont.register(folder: folder))
    }

    func testDigitCellsFitTheWidestFigure() throws {
        XCTAssertTrue(PVFont.register(folder: Self.fontFolder))
        let font = try XCTUnwrap(PVFont.ctFont(size: 24, weight: 400, soft: 100, italic: false))
        let cell = try XCTUnwrap(PVFont.resolve(size: 24, weight: 400, soft: 100, italic: false).digitCell)
        for digit in "0123456789" {
            let width = NSAttributedString(string: String(digit), attributes: [.font: font as NSFont]).size().width
            XCTAssertLessThanOrEqual(width, cell, "\(digit)")
        }
    }

    func testAMissingFamilyFallsBackInsteadOfFailing() {
        XCTAssertNil(PVFont.ctFont(size: 40, weight: 480, soft: 40, italic: false, family: "Fraunces Missing"))
        XCTAssertEqual(
            PVFont.resolve(size: 40, weight: 480, soft: 40, italic: false, family: "Fraunces Missing").font,
            Font.system(size: 40, weight: .medium, design: .serif).monospacedDigit())
        XCTAssertNil(
            PVFont.resolve(size: 40, weight: 480, soft: 40, italic: false, family: "Fraunces Missing").digitCell)
        XCTAssertFalse(PVFont.registerBundledFonts(in: Bundle(for: Self.self)), "the test bundle ships no fonts")
    }

    func testFallbackWeightsRoundToTheNearestSystemWeight() {
        XCTAssertEqual(PVFont.fallbackWeight(340), .light)
        XCTAssertEqual(PVFont.fallbackWeight(420), .regular)
        XCTAssertEqual(PVFont.fallbackWeight(480), .medium)
        XCTAssertEqual(PVFont.fallbackWeight(520), .medium)
    }

    func testTimeCodesSetOnlyThePositionInSFMono() throws {
        let line = PVFont.timeCoded("Sprint 02:18 · Demo", at: "02:18")
        XCTAssertEqual(String(line.characters), "Sprint 02:18 · Demo · 02:18")
        let mono = PVFont.timeCode()
        XCTAssertEqual(mono, Font.system(.caption, design: .monospaced, weight: .regular))
        let monoRuns = line.runs.filter { $0.font == mono }.map { String(line[$0.range].characters) }
        XCTAssertEqual(monoRuns, ["02:18"], "only the trailing position, not a title that quotes one")
        XCTAssertTrue(line.runs.contains { $0.font == nil }, "the rest keeps the surrounding font")

        let placed = PVFont.timeCoded("Sprint 02:18 · 02:18", time: "02:18")
        let placedMono = placed.runs.filter { $0.font == mono }
        XCTAssertEqual(placedMono.count, 1)
        XCTAssertEqual(
            placedMono.first.map { String(placed[$0.range.lowerBound...].characters) }, "02:18",
            "a localized line marks the last occurrence, not a title that quotes the same time")

        let untimed = PVFont.timeCoded("unheard", time: nil)
        XCTAssertFalse(untimed.runs.contains { $0.font != nil })
    }
}
