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
        XCTAssertFalse(SettingsCategory.audio.matches("spotlight"))
    }
}
