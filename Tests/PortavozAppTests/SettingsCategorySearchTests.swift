import Foundation
import XCTest
@testable import portavoz_app

/// Every Settings search keyword group is its own catalog key with a Spanish
/// value, so merged panes stay discoverable in both languages.
final class SettingsCategorySearchTests: XCTestCase {
    func testEveryKeywordGroupHasASpanishTranslation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/Portavoz/Localizable.xcstrings")
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for category in SettingsCategory.allCases {
            for group in category.keywordGroups {
                let entry = strings[group] as? [String: Any]
                let spanish = ((entry?["localizations"] as? [String: Any])?["es"] as? [String: Any])
                let value = (spanish?["stringUnit"] as? [String: Any])?["value"] as? String
                XCTAssertFalse(
                    (value ?? "").isEmpty,
                    "\(category.rawValue): keyword group needs a Spanish value: \(group.prefix(40))")
            }
        }
        XCTAssertEqual(SettingsCategory.data.keywordGroups.count, 3)
        XCTAssertEqual(SettingsCategory.intelligence.keywordGroups.count, 2)
    }

    func testEnglishKeywordsMatchTheirMergedPane() {
        XCTAssertTrue(SettingsCategory.data.matches("recordings"))
        XCTAssertTrue(SettingsCategory.data.matches("icloud"))
        XCTAssertTrue(SettingsCategory.data.matches("spotlight"))
        XCTAssertTrue(SettingsCategory.intelligence.matches("enroll"))
        XCTAssertTrue(SettingsCategory.intelligence.matches("memory"))
        XCTAssertTrue(SettingsCategory.intelligence.matches("RAM"))
        XCTAssertFalse(SettingsCategory.general.matches("lightweight"))
        XCTAssertFalse(SettingsCategory.audio.matches("spotlight"))
    }

    func testRelocatedControlsAndSubtitlesMatchExactCategoriesInBothLanguages() throws {
        // Post-meeting Shortcut moved to Automations (.skills), not General.
        XCTAssertTrue(SettingsCategory.skills.matches("shortcut", language: .english))
        XCTAssertFalse(SettingsCategory.general.matches("shortcut", language: .english))

        // Whisper and Vocabulary moved out of Intelligence into Audio & transcription.
        XCTAssertTrue(SettingsCategory.audio.matches("whisper", language: .english))
        XCTAssertTrue(SettingsCategory.audio.matches("vocabulary", language: .english))
        XCTAssertFalse(SettingsCategory.intelligence.matches("whisper", language: .english))
        XCTAssertFalse(SettingsCategory.intelligence.matches("refine", language: .english))
        XCTAssertFalse(SettingsCategory.intelligence.matches("vocabulary", language: .english))

        // Talk-time mirror in General, CLI/providers in Automations, Semantic search in Intelligence,
        // and subtitle terms like diagnostics/storage in Data & privacy.
        XCTAssertTrue(SettingsCategory.general.matches("mirror", language: .english))
        XCTAssertTrue(SettingsCategory.general.matches("talk", language: .english))
        XCTAssertTrue(SettingsCategory.skills.matches("cli", language: .english))
        XCTAssertTrue(SettingsCategory.skills.matches("providers", language: .english))
        XCTAssertTrue(SettingsCategory.intelligence.matches("semantic", language: .english))
        XCTAssertTrue(SettingsCategory.data.matches("diagnostics", language: .english))
        XCTAssertTrue(SettingsCategory.data.matches("storage", language: .english))

        // Verify Spanish catalog strings route relocated controls to the exact category too
        // (swift test runs under xctest rather than the compiled .lproj app bundle).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/Portavoz/Localizable.xcstrings")
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        func spanishCorpus(for category: SettingsCategory) -> String {
            ([category.titleKey, category.subtitleKey] + category.keywordGroups).compactMap { key in
                let entry = strings[key] as? [String: Any]
                let es = ((entry?["localizations"] as? [String: Any])?["es"] as? [String: Any])
                return ((es?["stringUnit"] as? [String: Any])?["value"] as? String)?.lowercased()
            }.joined(separator: " ")
        }
        XCTAssertTrue(spanishCorpus(for: .skills).contains("atajo"))
        XCTAssertFalse(spanishCorpus(for: .general).contains("atajo"))
        XCTAssertTrue(spanishCorpus(for: .audio).contains("vocabulario"))
        XCTAssertTrue(spanishCorpus(for: .audio).contains("transcripción"))
        XCTAssertFalse(spanishCorpus(for: .intelligence).contains("vocabulario"))
        XCTAssertFalse(spanishCorpus(for: .intelligence).contains("whisper"))
        XCTAssertTrue(spanishCorpus(for: .general).contains("espejo"))
        XCTAssertTrue(spanishCorpus(for: .skills).contains("proveedores"))
        XCTAssertTrue(spanishCorpus(for: .intelligence).contains("semántica"))
        XCTAssertTrue(spanishCorpus(for: .data).contains("diagnóstico"))
    }
}
