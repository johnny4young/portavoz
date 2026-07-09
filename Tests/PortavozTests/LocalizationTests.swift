import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // file -> PortavozTests
        .deletingLastPathComponent()  // -> Tests
        .deletingLastPathComponent()  // -> repo root

    private static let catalogPaths = [
        "Resources/Localization/Portavoz/Localizable.xcstrings",
        "Resources/Localization/Portavoz/InfoPlist.xcstrings"
    ]

    func testEveryCatalogKeyHasSpanishTranslation() throws {
        for catalog in try Self.loadCatalogs() {
            XCTAssertFalse(catalog.strings.isEmpty, "\(catalog.path) must not be empty")
            for (key, value) in catalog.strings {
                let units = Self.esUnits(value)
                XCTAssertFalse(units.isEmpty, "\(catalog.path): '\(key)' has no es value")
                for unit in units {
                    XCTAssertEqual(
                        unit.state, "translated",
                        "\(catalog.path): '\(key)' is missing a translated es value")
                    XCTAssertFalse(
                        unit.value.isEmpty,
                        "\(catalog.path): '\(key)' has an empty es value")
                }
            }
        }
    }

    func testFormatPlaceholdersMatchSpanishTranslations() throws {
        for catalog in try Self.loadCatalogs() {
            for (key, value) in catalog.strings {
                for unit in Self.esUnits(value) {
                    XCTAssertEqual(
                        Self.placeholders(in: key),
                        Self.placeholders(in: unit.value),
                        "\(catalog.path): placeholder mismatch in '\(key)' -> '\(unit.value)'")
                }
            }
        }
    }

    func testAppProseLiteralsAreCataloged() throws {
        let localizable = try Self.catalog(at: "Resources/Localization/Portavoz/Localizable.xcstrings")
        let keys = Set(localizable.strings.keys)
        let appDir = Self.repoRoot.appendingPathComponent("Sources/portavoz-app")
        let files = try FileManager.default.subpathsOfDirectory(atPath: appDir.path)
            .filter { $0.hasSuffix(".swift") }

        let regexes = try [
            #"(?:Text|Label|Button|Toggle|Menu|Section|Picker|TextField|SecureField|LabeledContent|ContentUnavailableView)\(\s*\"([^\"\\]+)\""#,
            #"\.(?:navigationTitle|alert|confirmationDialog|help)\(\s*\"([^\"\\]+)\""#,
            #"L10n\.(?:text|format)\(\s*\"([^\"\\]+)\""#
        ].map { try NSRegularExpression(pattern: $0) }
        let shortVisible = Set([
            "Add", "Apply", "Audio", "Cancel", "Delete", "Discard", "English", "Español",
            "GitHub", "Language", "Model", "OK", "Portavoz", "Recordings", "Reset", "Save",
            "Summary", "Transcript", "Vocabulary"
        ])

        for file in files {
            let source = try String(contentsOf: appDir.appendingPathComponent(file), encoding: .utf8)
            for regex in regexes {
                let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
                for match in matches {
                    guard let range = Range(match.range(at: 1), in: source) else { continue }
                    let literal = String(source[range])
                    guard !literal.contains(#"\("#) else { continue }
                    guard literal.contains(" ") || shortVisible.contains(literal) else { continue }
                    XCTAssertTrue(keys.contains(literal), "Sources/portavoz-app/\(file): '\(literal)' is not in Localizable.xcstrings")
                }
            }
        }
    }

    func testExporterProducesRuntimeStrings() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-l10n-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let process = Process()
        process.currentDirectoryURL = Self.repoRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["scripts/export-localizations.py", destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        for locale in ["en", "es"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent("\(locale).lproj/Localizable.strings").path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent("\(locale).lproj/InfoPlist.strings").path))
        }

        let englishInfo = try Self.stringsTable(
            at: destination.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let spanishInfo = try Self.stringsTable(
            at: destination.appendingPathComponent("es.lproj/InfoPlist.strings"))
        XCTAssertEqual(
            englishInfo["NSMicrophoneUsageDescription"],
            "Portavoz records your microphone to transcribe your side of the meeting. Audio never leaves your Mac.")
        XCTAssertEqual(
            spanishInfo["NSMicrophoneUsageDescription"],
            "Portavoz graba tu micrófono para transcribir tus intervenciones en la reunión. El audio nunca sale de tu Mac.")
        XCTAssertEqual(spanishInfo["CFBundleDisplayName"], "Portavoz")
        XCTAssertNil(
            spanishInfo["Portavoz records your microphone to transcribe your side of the meeting. Audio never leaves your Mac."],
            "InfoPlist.strings must be keyed by Info.plist keys, not source values")
    }

    private struct Catalog {
        let path: String
        let strings: [String: [String: Any]]
    }

    private static func loadCatalogs() throws -> [Catalog] {
        try catalogPaths.map { try catalog(at: $0) }
    }

    private static func catalog(at path: String) throws -> Catalog {
        let url = repoRoot.appendingPathComponent(path)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = (object?["strings"] as? [String: [String: Any]]) ?? [:]
        return Catalog(path: path, strings: strings)
    }

    private static func stringsTable(at url: URL) throws -> [String: String] {
        let table = NSDictionary(contentsOf: url) as? [String: String]
        return try XCTUnwrap(table, "Could not parse \(url.path)")
    }

    private static func esUnits(_ value: [String: Any]) -> [(state: String?, value: String)] {
        guard let es = (value["localizations"] as? [String: Any])?["es"] as? [String: Any] else {
            return []
        }
        if let unit = es["stringUnit"] as? [String: Any] {
            return [(unit["state"] as? String, unit["value"] as? String ?? "")]
        }
        return []
    }

    private static func placeholders(in text: String) -> [String] {
        let pattern = #"%(\d+\$)?[@dDfFsScCuUxXo%]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { $0 != "%%" }
            .sorted()
    }
}
