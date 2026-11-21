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
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fontFolder.path).sorted()
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
}
