import XCTest

@testable import portavoz_app

final class SkillsSettingsCategoryTests: XCTestCase {
    func testSkillsCategoryKeepsItsIdentityTitleAndSearchTerms() {
        XCTAssertEqual(SettingsCategory.skills.rawValue, "skills")
        XCTAssertEqual(SettingsCategory.skills.titleKey, "Automations")
        for query in ["actions", "suggestions", "skills", "automation", "pause", "enable", "history"] {
            XCTAssertTrue(SettingsCategory.skills.matches(query, language: .english), query)
        }
    }
}
